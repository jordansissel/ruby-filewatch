require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class Watch
    attr_accessor :delimiter
    attr_reader :logger, :max_active, :discoverer

    def initialize(opts={})
      if opts[:logger]
        @logger = opts[:logger]
      else
        @logger = Logger.new(STDERR)
        @logger.level = Logger::INFO
      end
      # we need to be threadsafe about the mutation
      # of the above 2 ivars because the public
      # methods each, discover and watch
      # can be called from different threads.
      @lock = Mutex.new
      # we need to be threadsafe about the quit mutation
      @quit = false
      @quit_lock = Mutex.new
      self.max_open_files = ENV["FILEWATCH_MAX_OPEN_FILES"].to_i
      @lastwarn_max_files = 0
    end # def initialize

    public

    def logger=(loggr)
      @discoverer.logger = loggr if @discoverer
      @logger = loggr
    end

    def add_discoverer(discoverer)
      @discoverer = discoverer
      self
    end

    def max_open_files=(value)
      val = value.to_i
      val = 4095 if value.nil? || val <= 0
      @max_warn_msg = "Reached open files limit: #{val}, set by the 'max_open_files' option or default"
      @max_active = val
    end

    def watch(path)
      synchronized do
        @discoverer.add_path(path)
      end
      return true
    end

    # Calls &block with params [event_type, path]
    # event_type can be one of:
    #   :create_initial - initially present file (so start at end for tail)
    #   :create - file is created (new file after initial globs, start at 0)
    #   :grow   - file has more content
    #   :shrink - file has less content
    #   :delete   - file can't be read
    #   :timeout - file is closable
    #   :unignore - file was ignored, but since then it received new content
    def each(&block)
      synchronized do
        return if @discoverer.empty?
        begin
          file_deletable = []
          # creates this array just once
          watched_files = @discoverer.watched_files

          # look at the closed to see if its changed
          watched_files.select {|wf| wf.closed? }.each do |watched_file|
            path = watched_file.path
            break if quit?
            begin
              stat = watched_file.restat
              if watched_file.size_changed?
                # if the closed file changed, move it to the watched state
                # not to active state because we want to use MAX_OPEN_FILES throttling.
                watched_file.invalidate_fingerprints!
                watched_file.watch
              end
            rescue Errno::ENOENT
              # file has gone away or we can't read it anymore.
              file_deletable << path
              @logger.debug? && @logger.debug("Watch each: closed?: stat failed: #{path}: (#{$!}), deleting from @files")
            rescue => e
              @logger.error("Watch each: closed?: #{path}: (#{e.inspect})")
            end
          end
          return if quit?

          # look at the ignored to see if its changed
          watched_files.select {|wf| wf.ignored? }.each do |watched_file|
            path = watched_file.path
            break if quit?
            begin
              stat = watched_file.restat
              if watched_file.size_changed?
                # if the ignored file changed, move it to the watched state
                # not to active state because we want to use MAX_OPEN_FILES throttling.
                # this file has not been yielded to the block yet
                # but we must have the tail to start from the end, so when the file
                # was first ignored we updated the bytes_read to the stat.size at that time.
                # by adding this to the sincedb so that the subsequent modify
                # event can detect the change
                watched_file.invalidate_fingerprints!
                watched_file.watch
                yield(:unignore, watched_file)
              end
            rescue Errno::ENOENT
              # file has gone away or we can't read it anymore.
              file_deletable << path
              @logger.debug? && @logger.debug("each: ignored: stat failed: #{path}: (#{$!}), deleting from @files")
            rescue => e
              @logger.error("each: ignored?: #{path}: (#{e.inspect}), #{e.backtrace.inspect}")
            end
          end

          return if quit?

          # Send any creates.
          if (to_take = @max_active - watched_files.count{|wf| wf.active?}) > 0
            watched_files.select {|wf| wf.watched?}.take(to_take).each do |watched_file|
              break if quit?
              path = watched_file.path
              begin

                stat = watched_file.restat
                watched_file.activate
                # skip the open now because we can't have a
                # file opened without a sincedb entry
                next if watched_file.unstorable?
                # don't do create again
                next if watched_file.state_history_any?(:closed, :ignored)
                # if the file can't be opened during the yield
                # its state is set back to watched
                if watched_file.grown? || watched_file.shrunk?
                  @logger.debug? && @logger.debug("Watch Watch each: activating: invalidating fps for path #{path}")
                  watched_file.invalidate_fingerprints!
                end
                sym = watched_file.initial? ? :create_initial : :create
                yield(sym, watched_file)
              rescue Errno::ENOENT
                # file has gone away or we can't read it anymore.
                file_deletable << path
                watched_file.unwatch
                yield(:delete, watched_file)
                next
                @logger.debug? && @logger.debug("Watch each: watched?: stat failed: #{path}: (#{$!}), deleting from @files")
              rescue => e
                @logger.error("Watch each: watched?: #{path}: (#{e.inspect}, #{e.backtrace.take(8).inspect})")
              end
            end
          else
            now = Time.now.to_i
            if (now - @lastwarn_max_files) > MAX_FILES_WARN_INTERVAL
              waiting = watched_files.size - @max_active
              specific = if @close_older.nil?
               ", try setting close_older. There are #{waiting} unopened files"
              else
                ", files yet to open: #{waiting}"
              end
              @logger.warn(@max_warn_msg + specific)
              @lastwarn_max_files = now
            end
          end

          return if quit?

          # wf.active means the actual files were opened
          # and have been read once - unless they were empty at the time
          watched_files.select {|wf| wf.active? }.each do |watched_file|
            path = watched_file.path
            break if quit?
            begin
              stat = watched_file.restat
            rescue Errno::ENOENT
              # file has gone away or we can't read it anymore.
              file_deletable << path
              @logger.debug? && @logger.debug("Watch each: active: stat failed: #{path}: (#{$!}), deleting from @files")
              watched_file.unwatch
              yield(:delete, watched_file)
              next
            rescue => e
              @logger.error("Watch each: active?: #{path}: (#{e.inspect})")
              next
            end

            if watched_file.file_closable?
              @logger.debug? && @logger.debug("Watch each: active: file expired: #{path}")
              yield(:timeout, watched_file)
              watched_file.close
              next
            end

            shrinking = watched_file.shrunk?
            growing = watched_file.grown?

            next unless growing || shrinking

            # we don't update the size here, its updated when we actually read
            if shrinking
              @logger.debug? && @logger.debug("Watch each: file rolled: #{path}: new size is #{stat.size}, old size #{watched_file.bytes_read}")
              if watched_file.invalidate_fingerprints!
                # reset storage_key, old sincedb record is orphaned
                watched_file.file_close
                # if truncated fully
                # no action, wait for grow
                if !watched_file.unstorable?
                  # truncated fully with new content
                  # but new file not in sincedb
                  yield(:shrink, watched_file)
                end
              else
                # truncated partially and in sincedb
                # read from eof
                yield(:shrink, watched_file)
              end
            end

            if growing
              @logger.debug? && @logger.debug("Watch each: file grew: #{path}: old size #{watched_file.bytes_read}, new size #{stat.size}")
              if watched_file.invalidate_fingerprints!
                # reset storage_key, old sincedb record is orphaned
                # was the file opened before?
                if watched_file.file_open?
                  # new file content
                  watched_file.file_close
                  yield(:grow, watched_file)
                else
                  yield(:create, watched_file)
                end
              else
                yield(:grow, watched_file)
              end

            end
          end
        ensure
          @discoverer.delete(file_deletable)
        end
      end
    end # def each

    def discover
      synchronized do
        @discoverer.discover
      end
    end

    def subscribe(stat_interval = 1, discover_interval = 5, &block)
      glob = 0
      reset_quit
      while !quit?
        each(&block)
        break if quit?
        glob += 1
        if glob == discover_interval
          discover
          glob = 0
        end
        break if quit?
        sleep(stat_interval)
      end
      @discoverer.close_all
    end # def subscribe

    def quit
      @quit_lock.synchronize { @quit = true }
    end # def quit

    def quit?
      @quit_lock.synchronize { @quit }
    end

    private

    def synchronized(&block)
      @lock.synchronize { block.call }
    end

    def reset_quit
      @quit_lock.synchronize { @quit = false }
    end
  end # class Watch
end # module FileWatch

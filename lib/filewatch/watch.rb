require "logger"
require_relative 'watched_file'

if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
  require "filewatch/winhelper"
  FILEWATCH_INODE_METHOD = :win_inode
else
  FILEWATCH_INODE_METHOD = :nix_inode
end

module FileWatch
  # TODO make a WatchedFilesDb class that holds the watched_files instead of a hash
  # it should support an 'identity' of path + inode
  # it should be serializable instead of the sincedb
  # it should be deserializable to recreate the exact state all files were in as last seen
  # some parts of the each method should be handled by it, e.g.
  # wfs_db.<state>_iterator{|wf| }, trapping the Errno::ENOENT, auto_delete and yield wtached_file
  class Watch

    MAX_FILES_WARN_INTERVAL = ENV.fetch("FILEWATCH_MAX_FILES_WARN_INTERVAL", 20).to_i

    def self.win_inode(path, stat)
      fileId = Winhelper.GetWindowsUniqueFileIdentifier(path)
      [fileId, 0, 0] # dev_* doesn't make sense on Windows
    end

    def self.nix_inode(path, stat)
      [stat.ino.to_s, stat.dev_major, stat.dev_minor]
    end

    def self.inode(path, stat)
      send(FILEWATCH_INODE_METHOD, path, stat)
    end

    attr_accessor :logger
    attr_accessor :delimiter
    attr_reader :max_active

    def initialize(opts={})
      if opts[:logger]
        @logger = opts[:logger]
      else
        @logger = Logger.new(STDERR)
        @logger.level = Logger::INFO
      end
      @watching = []
      @exclude = []
      @files = Hash.new
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

    def max_open_files=(value)
      val = value.to_i
      val = 4095 if value.nil? || val <= 0
      @max_warn_msg = "Reached open files limit: #{val}, set by the 'max_open_files' option or default"
      @max_active = val
    end

    def ignore_older=(value)
      #nil is allowed but 0 and negatives are made nil
      if !value.nil?
        val = value.to_f
        val = val <= 0 ? nil : val
      end
      @ignore_older = val
    end

    def close_older=(value)
      if !value.nil?
        val = value.to_f
        val = val <= 0 ? nil : val
      end
      @close_older = val
    end

    def exclude(path)
      path.to_a.each { |p| @exclude << p }
    end

    def watch(path)
      synchronized do
        if !@watching.member?(path)
          @watching << path
          _discover_file(path) do |filepath, stat|
            WatchedFile.new_initial(
                filepath, inode(filepath, stat), stat
              ).init_vars(@delimiter, @ignore_older, @close_older)
          end
        end
      end
      return true
    end # def watch

    def inode(path, stat)
      self.class.inode(path, stat)
    end

    # Calls &block with params [event_type, path]
    # event_type can be one of:
    #   :create_initial - initially present file (so start at end for tail)
    #   :create - file is created (new file after initial globs, start at 0)
    #   :modify - file is modified (size increases)
    #   :delete - file is deleted
    #   :timeout - file is closable
    #   :unignore - file was ignored, but since then it received new content
    def each(&block)
      synchronized do
        return if @files.empty?
        begin
          file_deletable = []
          # creates this array just once
          watched_files = @files.values

          # look at the closed to see if its changed
          watched_files.select {|wf| wf.closed? }.each do |watched_file|
            path = watched_file.path
            break if quit?
            begin
              stat = watched_file.restat
              if watched_file.size_changed? || watched_file.inode_changed?(inode(path,stat))
                # if the closed file changed, move it to the watched state
                # not to active state because we want to use MAX_OPEN_FILES throttling.
                watched_file.watch
              end
            rescue Errno::ENOENT
              # file has gone away or we can't read it anymore.
              file_deletable << path
              @logger.debug? && @logger.debug("each: closed?: stat failed: #{path}: (#{$!}), deleting from @files")
            rescue => e
              @logger.error("each: closed?: #{path}: (#{e.inspect})")
            end
          end
          return if quit?

          # look at the ignored to see if its changed
          watched_files.select {|wf| wf.ignored? }.each do |watched_file|
            path = watched_file.path
            break if quit?
            begin
              stat = watched_file.restat
              if watched_file.size_changed? || watched_file.inode_changed?(inode(path,stat))
                # if the ignored file changed, move it to the watched state
                # not to active state because we want to use MAX_OPEN_FILES throttling.
                # this file has not been yielded to the block yet
                # but we must have the tail to start from the end, so when the file
                # was first ignored we updated the bytes_read to the stat.size at that time.
                # by adding this to the sincedb so that the subsequent modify
                # event can detect the change
                watched_file.watch
                yield(:unignore, watched_file)
              end
            rescue Errno::ENOENT
              # file has gone away or we can't read it anymore.
              file_deletable << path
              @logger.debug? && @logger.debug("each: ignored: stat failed: #{path}: (#{$!}), deleting from @files")
            rescue => e
              @logger.error("each: ignored?: #{path}: (#{e.inspect})")
            end
          end

          return if quit?

          # Send any creates.
          if (to_take = @max_active - watched_files.count{|wf| wf.active?}) > 0
            watched_files.select {|wf| wf.watched? }.take(to_take).each do |watched_file|
              break if quit?
              path = watched_file.path
              begin
                stat = watched_file.restat
                watched_file.activate
                # don't do create again
                next if watched_file.state_history_any?(:closed, :ignored)
                # if the file can't be opened during the yield
                # its state is set back to watched
                sym = watched_file.initial? ? :create_initial : :create
                yield(sym, watched_file)
              rescue Errno::ENOENT
                # file has gone away or we can't read it anymore.
                file_deletable << path
                watched_file.unwatch
                yield(:delete, watched_file)
                next
                @logger.debug? && @logger.debug("each: closed: stat failed: #{path}: (#{$!}), deleting from @files")
              rescue => e
                @logger.error("each: watched?: #{path}: (#{e.inspect})")
              end
            end
          else
            now = Time.now.to_i
            if (now - @lastwarn_max_files) > MAX_FILES_WARN_INTERVAL
              waiting = @files.size - @max_active
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
              @logger.debug? && @logger.debug("each: active: stat failed: #{path}: (#{$!}), deleting from @files")
              watched_file.unwatch
              yield(:delete, watched_file)
              next
            rescue => e
              @logger.error("each: active?: #{path}: (#{e.inspect})")
              next
            end

            if watched_file.file_closable?
              @logger.debug? && @logger.debug("each: active: file expired: #{path}")
              yield(:timeout, watched_file)
              watched_file.close
              next
            end

            _inode = inode(path,stat)
            read_thus_far = watched_file.bytes_read
            # we don't update the size here, its updated when we actually read
            if watched_file.inode_changed?(_inode)
              @logger.debug? && @logger.debug("each: new inode: #{path}: old inode was #{watched_file.inode.inspect}, new is #{_inode.inspect}")
              watched_file.update_inode(_inode)
              yield(:delete, watched_file)
              yield(:create, watched_file)
            elsif stat.size < read_thus_far
              @logger.debug? && @logger.debug("each: file rolled: #{path}: new size is #{stat.size}, old size #{read_thus_far}")
              yield(:delete, watched_file)
              yield(:create, watched_file)
            elsif stat.size > read_thus_far
              @logger.debug? && @logger.debug("each: file grew: #{path}: old size #{read_thus_far}, new size #{stat.size}")
              yield(:modify, watched_file)
            end
          end
        ensure
          file_deletable.each {|f| @files.delete(f)}
        end
      end
    end # def each

    def discover
      synchronized do
        @watching.each do |path|
          _discover_file(path) do |filepath, stat|
            WatchedFile.new_ongoing(
                filepath, inode(filepath, stat), stat
              ).init_vars(@delimiter, @ignore_older, @close_older)
          end
        end
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
      @files.values.each(&:file_close)
    end # def subscribe

    def quit
      @quit_lock.synchronize { @quit = true }
    end # def quit

    def quit?
      @quit_lock.synchronize { @quit }
    end

    private

    def _discover_file(path)
      _globbed_files(path).each do |file|
        next unless File.file?(file)
        new_discovery = false
        if @files.member?(file)
          watched_file = @files[file]
        else
          @logger.debug? && @logger.debug("_discover_file: #{path}: new: #{file} (exclude is #{@exclude.inspect})")
          # let the caller build the object in its context
          new_discovery = true
          watched_file = yield(file, File::Stat.new(file))
        end

        skip = false
        @exclude.each do |pattern|
          if File.fnmatch?(pattern, File.basename(file))
            @logger.debug? && @logger.debug("_discover_file: #{file}: skipping because it " +
                          "matches exclude #{pattern}") if new_discovery
            skip = true
            watched_file.unwatch
            break
          end
        end
        next if skip

        if new_discovery
          if watched_file.file_ignorable?
            @logger.debug? && @logger.debug("_discover_file: #{file}: skipping because it was last modified more than #{@ignore_older} seconds ago")
            # on discovery we put watched_file into the ignored state and that
            # updates the size from the internal stat
            # so the existing contents are not read.
            # because, normally, a newly discovered file will
            # have a watched_file size of zero
            watched_file.ignore
          end
          @files[file] = watched_file
        end
      end
    end # def _discover_file

    private
    def _globbed_files(path)
      globbed_dirs = Dir.glob(path)
      @logger.debug? && @logger.debug("_globbed_files: #{path}: glob is: #{globbed_dirs}")
      if globbed_dirs.empty? && File.file?(path)
        globbed_dirs = [path]
        @logger.debug? && @logger.debug("_globbed_files: #{path}: glob is: #{globbed_dirs} because glob did not work")
      end
      # return Enumerator
      globbed_dirs.to_enum
    end

    private
    def synchronized(&block)
      @lock.synchronize { block.call }
    end

    public

    private
    def reset_quit
      @quit_lock.synchronize { @quit = false }
    end
  end # class Watch
end # module FileWatch

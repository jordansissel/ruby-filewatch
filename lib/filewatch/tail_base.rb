require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  module TailBase
    attr_reader :logger

    public
    # TODO move sincedb to watch.rb
    # see TODO there
    def initialize(opts={})
      if opts[:logger]
        @logger = opts[:logger]
      else
        @logger = Logger.new(STDERR)
        @logger.level = Logger::INFO
      end
      @opts = {
        :sincedb_write_interval => 10,
        :stat_interval => 1,
        :discover_interval => 5,
        :exclude => [],
        :start_new_files_at => :end,
        :delimiter => "\n",
        :read_iterations => FIXNUM_MAX
      }.merge(opts)
      if !@opts.include?(:sincedb_path)
        @opts[:sincedb_path] = File.join(ENV["HOME"], ".sincedb") if ENV.include?("HOME")
        @opts[:sincedb_path] = ENV["SINCEDB_PATH"] if ENV.include?("SINCEDB_PATH")
      end
      if !@opts.include?(:sincedb_path)
        raise NoSinceDBPathGiven.new("No HOME or SINCEDB_PATH set in environment. I need one of these set so I can keep track of the files I am following.")
      end
      @watch = build_watch(@opts, @logger)
      @delimiter_byte_size = @opts[:delimiter].bytesize
    end

    def build_watch(opts, logger)
      discoverer = Discover.new(opts, logger)
      @sincedb = SinceDb.new(opts, logger)
      discoverer.add_converter(SinceDbConverter.new(@sincedb, logger))
      watch = Watch.new(opts).add_discoverer(discoverer)
      watch.max_open_files = opts[:max_open_files]
      watch
    end

    def logger=(logger)
      @logger = logger
      @watch.logger = logger
      @sincedb.logger = logger
    end # def logger=

    def tail(path)
      @watch.watch(path)
    end # def tail

    def sincedb_write(reason=nil)
      @sincedb.write(reason)
    end

    # quit is a sort-of finalizer,
    # it should be called for clean up
    # before the instance is disposed of.
    def quit
      @watch.quit # <-- should close all the files
    end # def quit

    # close_file(path) is to be used by external code
    # when it knows that it is completely done with a file.
    # Other files or folders may still be being watched.
    # Caution, once unwatched, a file can't be watched again
    # unless a new instance of this class begins watching again.
    # The sysadmin should rename, move or delete the file.
    def close_file(path)
      @watch.unwatch(path)
      sincedb_write
    end

    private

    def _open_file(watched_file, event)
      _add_to_sincedb(watched_file, event) do
        path = watched_file.path
        @logger.debug? && @logger.debug("_open_file: #{path}: opening")
        begin
          watched_file.open
        rescue
          # don't emit this message too often. if a file that we can't
          # read is changing a lot, we'll try to open it more often,
          # and might be spammy.
          now = Time.now.to_i
          if now - @lastwarn[path] > OPEN_WARN_INTERVAL
            @logger.warn("failed to open #{path}: #{$!}")
            @lastwarn[path] = now
          else
            @logger.debug? && @logger.debug("(warn supressed) failed to open #{path}: #{$!.inspect}")
          end
          watched_file.watch # set it back to watch so we can try it again
        end
      end
    end # def _open_file

    def _add_to_sincedb(watched_file, event)
      # has_block = block_given?
      # don't store if watched_file has no content (no fingerprints)
      return false if watched_file.unstorable?
      # called when newly discovered files are opened
      stat = watched_file.filestat
      path = watched_file.path
      sdb_key = watched_file.storage_key
      # NOTE: during initializing the discovered files and sincedb are converted
      #   but only for old records
      #   so a watched file might already be in the sincedb
      sdb_value = @sincedb.find(watched_file, event)

      if sdb_value && sdb_value.watched_file == watched_file
        yield if block_given? # should open the file
        return false if !watched_file.file_open?
        # we have seen this fingerprint before
        # and it is allocated
        # its contents are the same
        # as another file we have watched before.
        last_read_size = sdb_value.position
        @logger.debug? && @logger.debug("#{path}: #{event}, in sincedb, last value #{last_read_size}, cur size #{stat.size}")
        case event
        when :create, :create_initial
          # a file with the same fingerprint as another has now been allocated to
          # this sdb_value and it is being processed now.
          # but we don't want to reread the data
          @logger.debug? && @logger.debug("_add_to_sincedb: #{path}: create, in sincedb, seeking to #{last_read_size}")
          watched_file.file_seek(last_read_size)
          # this sets the sdb_value and the watched_file bytes_read in sync and updates the sdb expiry
          @sincedb.store_last_read(sdb_key, last_read_size)
        when :grow
          # it has old content that was read and more now since the converter matched
          @logger.debug? && @logger.debug("_add_to_sincedb: #{path}: grow, in sincedb, seeking to #{last_read_size}")
          watched_file.file_seek(last_read_size)
          # this sets the sdb_value and the watched_file bytes_read in sync and updates the sdb expiry
          @sincedb.store_last_read(sdb_key, last_read_size)
        when :shrink
          # ?? we have a fingerprint match but less content - some must have been deleted
          # but not all because then there would be no content to fingerprint
          # so go to the eof and wait for new content.
          @logger.debug? && @logger.debug("_add_to_sincedb: #{path}: shrink, in sincedb, was not fully truncated, seeking to #{stat.size}")
          watched_file.file_seek(stat.size)
          # this sets the sdb_value and the watched_file bytes_read in sync and updates the sdb expiry
          @sincedb.store_last_read(sdb_key, stat.size)
        end
        return true
      elsif sdb_value && sdb_value.watched_file != watched_file
        # we have seen this fingerprint before
        # but it is allocated to a different file with the same (initial) content
        # wf is a renamed file recently discovered
        # or a different file with the same content
        # to process this file we need a different key
        # we will not open the file but we do deactivate it
        # maybe one of the fingerprints will change.
        watched_file.watch
        @logger.debug? && @logger.debug("_add_to_sincedb: #{path}: found but differently allocated")
        return false
      end
      sdb_value = SincedbValue.new(0)
      sdb_value.upd_watched_file(watched_file) # <-- allocate this watched_file to the sincedb value
      yield if block_given? # should open the file

      case event
      when :create_initial
        seek_to = 0
        if @opts[:start_new_files_at] == :beginning
          @logger.debug? && @logger.debug("_add_to_sincedb: #{path}: initial create, no sincedb on disk, seeking to beginning of file")
        else
          # seek to end
          @logger.debug? && @logger.debug("_add_to_sincedb: #{path}: initial create, no sincedb on disk, seeking to end #{stat.size}")
          seek_to = stat.size
        end
        watched_file.file_seek(seek_to)
        sdb_value.upd_position(seek_to)
        @sincedb.set(sdb_key, sdb_value)
      when :create, :shrink, :grow
        @logger.debug? && @logger.debug("_add_to_sincedb: #{path}: #{event}, new content, no sincedb on disk, seeking to beginning of file")
        sdb_value.upd_position(0)
        watched_file.file_seek(0)
        @sincedb.set(sdb_key, sdb_value)
      when :unignore
        # when this watched_file as ignored it had it bytes_read set to eof
        sdb_value.upd_position(watched_file.bytes_read)
        watched_file.file_seek(watched_file.bytes_read)
        @sincedb.set(sdb_key, sdb_value)
      else
        @logger.debug? && @logger.debug("_add_to_sincedb: #{path}: staying at position 0, no sincedb")
      end
      return true
    end # def _add_to_sincedb
  end # module TailBase
end # module FileWatch

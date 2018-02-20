# encoding: utf-8
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
      @last_warning = Hash.new { |h, k| h[k] = 0 }
      @watch = build_watch_and_dependencies(@opts, @logger)
      @delimiter_byte_size = @opts[:delimiter].bytesize
    end

    def build_watch_and_dependencies(opts, loggr)
      discoverer = Discover.new(opts, loggr)
      @sincedb = SinceDb.new(opts, loggr)
      discoverer.add_converter(SinceDbConverter.new(@sincedb, loggr))
      watch = Watch.new(opts).add_discoverer(discoverer)
      watch.max_open_files = opts[:max_open_files]
      watch
    end

    def logger=(logger)
      @logger = logger
      @watch.logger = logger
      @sincedb.logger = logger
    end # def logger=

    def serializer=(klass)
      @sincedb.serializer = klass.new
    end

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

    def open_file(watched_file, event)
      # called when newly discovered files need opening
      # don't store if watched_file has no content (no fingerprints)
      return false if watched_file.unstorable?
      result = open_file_if_stored(watched_file, event)
      # result may be true, false or nil?
      # true means we found it in the db
      # false means we found it but the second fingerprint did not match
      # nil means its not in the db
      return result unless result.nil?
      open_file_and_store(watched_file, event)
    end

    def attempt_to_open(watched_file)
      path = watched_file.path
      @logger.debug? && @logger.debug("_open_file: #{path}: opening")
      begin
        watched_file.open
      rescue
        # don't emit this message too often. if a file that we can't
        # read is changing a lot, we'll try to open it more often,
        # and might be spammy.
        now = Time.now.to_i
        if now - @last_warning[path] > OPEN_WARN_INTERVAL
          @logger.warn("failed to open #{path}: #{$!}")
          @last_warning[path] = now
        else
          @logger.debug? && @logger.debug("(warn supressed) failed to open #{path}: #{$!.inspect}")
        end
        watched_file.watch # set it back to watch so we can try it again
      end
    end

    def open_file_if_stored(watched_file, event)

      stat = watched_file.filestat
      path = watched_file.path
      sdb_key = watched_file.storage_key
      # NOTE: during initializing the discovered files and sincedb are converted
      #   but only for old records
      #   so a watched file might already be in the sincedb
      sdb_value = @sincedb.find(watched_file, event)

      if sdb_value && sdb_value.watched_file == watched_file

        attempt_to_open(watched_file)

        return false if !watched_file.file_open?
        # we have seen this fingerprint before
        # and it is allocated
        # its contents are the same
        # as another file we have watched before.
        last_read_size = sdb_value.position
        @logger.debug? && @logger.debug("already_stored_open_file: #{path}: #{event}, in sincedb, last value #{last_read_size}, cur size #{stat.size}")
        case event
        when :shrink
          # ?? we have a fingerprint match but less content - some must have been deleted
          # but not all because then there would be no content to fingerprint
          # so go to the eof and wait for new content.
          @logger.debug? && @logger.debug("already_stored_open_file: #{path}: shrink, in sincedb, was not fully truncated, seeking to #{stat.size}")
          watched_file.file_seek(stat.size)
          sdb_value.upd_position(stat.size)
        else
          # :create, :create_initial, :grow
          # a file with the same fingerprint as another has now
          # been set to this sdb_value and it is being processed now.
          # but we don't want to reread the data
          @logger.debug? && @logger.debug("already_stored_open_file: #{path}: #{event}, in sincedb, seeking to #{last_read_size}")
          watched_file.file_seek(last_read_size)
          sdb_value.upd_position(last_read_size) # ?? hmmmm: should be the same
        end
        true
      elsif sdb_value && sdb_value.watched_file != watched_file
        # we have seen this fingerprint before
        # but it is allocated to a different file with the same (initial) content
        # wf is a renamed file recently discovered
        # or a different file with the same content
        # to process this file we need a different key
        # we will not open the file but we do deactivate it
        # maybe one of the fingerprints will change.
        @logger.debug? && @logger.debug("already_stored_open_file: #{path}: found but differently allocated - setting wf back to watch for later retry")
        watched_file.watch
        false
      else
        nil
      end
    end

    def open_file_and_store(watched_file, event)
      #we have a watched_file that has never been seen before.
      attempt_to_open(watched_file)
      return false if !watched_file.file_open?

      sdb_value = SincedbValue.new(0)
      sdb_value.set_watched_file(watched_file) # <-- allocate this watched_file to the sincedb value
      seek_position = 0 #beginning
      case event
      when :create_initial
        if @opts[:start_new_files_at] == :beginning
          @logger.debug? && @logger.debug("store_and_open_file: #{path}: initial create, no sincedb on disk, seeking to beginning of file")
        else
          # seek to end
          @logger.debug? && @logger.debug("store_and_open_file: #{path}: initial create, no sincedb on disk, seeking to end #{stat.size}")
          seek_position = stat.size
        end
      when :create, :shrink, :grow
        @logger.debug? && @logger.debug("store_and_open_file: #{path}: #{event}, new content, no sincedb on disk, seeking to beginning of file")
      when :unignore
        # when this watched_file as ignored it had it bytes_read set to eof
        seek_position = watched_file.bytes_read
      else
        @logger.debug? && @logger.debug("store_and_open_file: #{path}: staying at position 0, no sincedb")
      end
      watched_file.file_seek(seek_position)
      sdb_value.upd_position(seek_position)
      @sincedb.set(watched_file.storage_key, sdb_value)
      return true
    end
  end # module TailBase
end # module FileWatch

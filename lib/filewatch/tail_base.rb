require "filewatch/discover"
require "filewatch/since_db"
require "filewatch/since_db_v2"
require "filewatch/since_db_upgrader"

require "filewatch/watch"
require "logger"

module FileWatch
  module TailBase
    # how often (in seconds) we @logger.warn a failed file open, per path.
    OPEN_WARN_INTERVAL = ENV.fetch("FILEWATCH_OPEN_WARN_INTERVAL", 300).to_i

    attr_reader :logger

    class NoSinceDBPathGiven < StandardError; end

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
        :delimiter => "\n"
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
      upgrader = FileWatch::SinceDbUpgrader.new(@watch.discoverer, @opts, @logger)
      @sincedb = upgrader.opened_sincedb
    end

    def build_watch(opts, logger)
      discoverer = FileWatch::Discover.new(opts, logger)
      watch = FileWatch::Watch.new(opts).add_discoverer(discoverer)
      watch.max_open_files = opts[:max_open_files]
      watch
    end

    def logger=(logger)
      @logger = logger
      @watch.logger = logger
    end # def logger=

    def tail(path)
      @watch.watch(path)
    end # def tail

    def sincedb_record_uid(path, stat)
      # retain this call because its part of the public API
      @watch.inode(path, stat)
    end

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
      path = watched_file.path
      @logger.debug? && @logger.debug("_open_file: #{path}: opening")
      begin
        if @iswindows && defined? JRUBY_VERSION
          watched_file.file_add_opened(Java::RubyFileExt::getRubyFile(path))
        else
          watched_file.file_add_opened(File.open(path))
        end
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
        return false
      end
      _add_to_sincedb(watched_file, event)
      true
    end # def _open_file

    def _add_to_sincedb(watched_file, event)
      # called when newly discovered files are opened
      stat = watched_file.filestat
      path = watched_file.path

      if @sincedb.member?(watched_file)
        # we have seen this inode before
        # but this is a new watched_file
        # and we can't tell if its contents are the same
        # as another file we have watched before.
        last_read_size = @sincedb.last_read(watched_file)
        @logger.debug? && @logger.debug("#{path}: sincedb last value #{last_read_size}, cur size #{stat.size}")
        if stat.size > last_read_size
          # 1) it could really be a new file with lots of new content
          # 2) it could have old content that was read plus new that is not
          @logger.debug? && @logger.debug("#{path}: sincedb: seeking to #{last_read_size}")
          watched_file.file_seek(last_read_size) # going with 2
          watched_file.update_bytes_read(last_read_size)
        elsif stat.size == last_read_size
          # 1) it could have old content that was read
          # 2) it could have new content that happens to be the same size
          @logger.debug? && @logger.debug("#{path}: sincedb: seeking to #{last_read_size}")
          watched_file.file_seek(last_read_size) # going with 1.
          watched_file.update_bytes_read(last_read_size)
        else
          # it seems to be a new file with less content
          @logger.debug? && @logger.debug("#{path}: last value size is greater than current value, starting over")
          @sincedb.rewind(watched_file)
          watched_file.update_bytes_read(0) if watched_file.bytes_read != 0
        end
      elsif event == :create_initial
        if @opts[:start_new_files_at] == :beginning
          @logger.debug? && @logger.debug("#{path}: initial create, no sincedb, seeking to beginning of file")
          watched_file.file_seek(0)
          @sincedb.rewind(watched_file)
        else
          # seek to end
          @logger.debug? && @logger.debug("#{path}: initial create, no sincedb, seeking to end #{stat.size}")
          watched_file.file_seek(stat.size)
          @sincedb.store_last_read(watched_file, stat.size)
        end
      elsif event == :create
        @sincedb.rewind(watched_file)
      elsif event == :modify && @sincedb.last_read(watched_file).nil?
        @sincedb.rewind(watched_file)
      elsif event == :unignore
        @sincedb.store_last_read(watched_file, watched_file.bytes_read)
      else
        @logger.debug? && @logger.debug("#{path}: staying at position 0, no sincedb")
      end
      return true
    end # def _add_to_sincedb

  end # module TailBase
end # module FileWatch

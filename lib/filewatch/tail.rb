require "filewatch/buftok"
require "filewatch/watch"
require "logger"

module FileWatch
  class Tail
    attr_accessor :logger

    public
    def initialize(opts={})
      @logger = Logger.new(STDERR)
      @files = {}
      @buffers = {}
      @watch = FileWatch::Watch.new
      @sincedb = {}  # TODO: load from disk
      @statcache = {}
    end # def initialize

    public
    def logger=(logger)
      @logger = logger
    end # def logger=

    public
    def tail(path)
      @watch.watch(path)
    end # def tail

    public
    def subscribe(&block)
      # subscribe(stat_interval = 1, discover_interval = 5, &block)
      @watch.subscribe do |event, path|
        case event
        when :create, :create_initial
          if @files.member?(path)
            @logger.debug("#{event} for #{path}: already exists in @files")
            next
          end
          _open_file(path, event)
        when :modify
          if !@files.member?(path)
            @logger.debug(":modify for #{path}, does not exist in @files")
            _open_file(path)
          end
          _read_file(path, &block)
        when :delete
          @logger.debug(":delete for #{path}, deleted from @files")
          _read_file(path, &block)
          @files[path].close
          @files.delete(path)
          @statcache.delete(path)
        else
          @logger.warn("unknown event type #{event} for #{path}")
        end
      end # @watch.subscribe
    end # def each

    private
    def _open_file(path, event)
      @logger.debug("_open_file: #{path}: opening")
      # TODO(petef): handle File.open failing
      begin
        @files[path] = File.open(path)
      rescue Errno::ENOENT
        @logger.warn("#{path}: open: #{$!}")
        @files.delete(path)
        return
      end

      stat = File::Stat.new(path)
      inode = [stat.ino, stat.dev_major, stat.dev_minor]
      @statcache[path] = inode

      if @sincedb.member?(inode)
        last_size = @sincedb[inode]
        @logger.debug("#{path}: sincedb last value #{@sincedb[inode]}, cur size #{stat.size}")
        if last_size <= stat.size
          @logger.debug("#{path}: sincedb: seeking to #{last_size}")
          @files[path].sysseek(last_size, IO::SEEK_SET)
        else
          @logger.debug("#{path}: last value size is greater than current value, starting over")
          @sincedb[inode] = 0
        end
      elsif event == :create_initial && @files[path]
        @logger.debug("#{path}: initial create, no sincedb, seeking to end #{stat.size}")
        @files[path].sysseek(stat.size, IO::SEEK_SET)
        @sincedb[inode] = stat.size
      else
        @logger.debug("#{path}: staying at position 0, no sincedb")
      end
    end # def _open_file

    private
    def _read_file(path, &block)
      @buffers[path] ||= BufferedTokenizer.new

      loop do
        begin
          data = @files[path].read_nonblock(4096)
          @buffers[path].extract(data).each do |line|
            yield(path, line)
          end

          @sincedb[@statcache[path]] = @files[path].pos
        rescue Errno::EWOULDBLOCK, Errno::EINTR, EOFError
          break
        end
      end
    end # def _read_file
  end # class Watch
end # module FileWatch

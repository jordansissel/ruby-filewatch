require 'filewatch/tail_base'

module FileWatch
  class ObservingTail
    include TailBase
    public

    class NullListener
      def initialize(path) @path = path; end
      def accept(line) end
      def deleted() end
      def created() end
      def error() end
      def eof() end
    end

    class NullObserver
      def listener_for(path) NullListener.new(path); end
    end

    def subscribe(observer = NullObserver.new)
      @watch.subscribe(@opts[:stat_interval],
                       @opts[:discover_interval]) do |event, path|
        listener = observer.listener_for(path)
        case event
        when :create, :create_initial
          if @files.member?(path)
            @logger.debug? && @logger.debug("#{event} for #{path}: already exists in @files")
            next
          end
          if _open_file(path, event)
            listener.created
            observe_read_file(path, listener)
          end
        when :modify
          if !@files.member?(path)
            @logger.debug? && @logger.debug(":modify for #{path}, does not exist in @files")
            if _open_file(path, event)
              observe_read_file(path, listener)
            end
          else
            observe_read_file(path, listener)
          end
        when :delete
          @logger.debug? && @logger.debug(":delete for #{path}, deleted from @files")
          if @files[path]
            observe_read_file(path, listener)
            @files[path].close
          end
          listener.deleted
          @files.delete(path)
          @statcache.delete(path)
        else
          @logger.warn("unknown event type #{event} for #{path}")
        end
      end # @watch.subscribe
    end # def subscribe

    private
    def observe_read_file(path, listener)
      @buffers[path] ||= FileWatch::BufferedTokenizer.new(@opts[:delimiter])
      delimiter_byte_size = @opts[:delimiter].bytesize
      changed = false
      loop do
        begin
          data = @files[path].sysread(32768)
          changed = true
          @buffers[path].extract(data).each do |line|
            listener.accept(line)
            @sincedb[@statcache[path]] += (line.bytesize + delimiter_byte_size)
          end
        rescue EOFError
          listener.eof
          break
        rescue Errno::EWOULDBLOCK, Errno::EINTR
          listener.error
          break
        end
      end

      if changed
        now = Time.now.to_i
        delta = now - @sincedb_last_write
        if delta >= @opts[:sincedb_write_interval]
          @logger.debug? && @logger.debug("writing sincedb (delta since last write = #{delta})")
          _sincedb_write
          @sincedb_last_write = now
        end
      end
    end # def _read_file
  end
end # module FileWatch

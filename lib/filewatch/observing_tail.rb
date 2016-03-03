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
      def timed_out() end
    end

    class NullObserver
      def listener_for(path) NullListener.new(path); end
    end

    def subscribe(observer = NullObserver.new)
      @watch.subscribe(@opts[:stat_interval],
                       @opts[:discover_interval]) do |event, watched_file|
        path = watched_file.path
        file_is_open = watched_file.file_open?
        listener = observer.listener_for(path)
        case event
        when :unignore
          listener.created
          _add_to_sincedb(watched_file, event) unless @sincedb.member?(watched_file.inode)
        when :create, :create_initial
          if file_is_open
            @logger.debug? && @logger.debug("#{event} for #{path}: file already open")
            next
          end
          if _open_file(watched_file, event)
            listener.created
            observe_read_file(watched_file, listener)
          end
        when :modify
          if file_is_open
            observe_read_file(watched_file, listener)
          else
            @logger.debug? && @logger.debug(":modify for #{path}, file is not open, opening now")
            if _open_file(watched_file, event)
              observe_read_file(watched_file, listener)
            end
          end
        when :delete
          if file_is_open
            @logger.debug? && @logger.debug(":delete for #{path}, closing file")
            observe_read_file(watched_file, listener)
            watched_file.file_close
          else
            @logger.debug? && @logger.debug(":delete for #{path}, file already closed")
          end
          listener.deleted
        when :timeout
          @logger.debug? && @logger.debug(":timeout for #{path}, closing file")
          watched_file.file_close
          listener.timed_out
        else
          @logger.warn("unknown event type #{event} for #{path}")
        end
      end # @watch.subscribe
      # when watch.subscribe ends - its because we got quit
      _sincedb_write
    end # def subscribe

    private
    def observe_read_file(watched_file, listener)
      changed = false
      loop do
        begin
          data = watched_file.file_read(32768)
          changed = true
          watched_file.buffer_extract(data).each do |line|
            listener.accept(line)
            @sincedb[watched_file.inode] += (line.bytesize + @delimiter_byte_size)
          end
          # watched_file bytes_read tracks the sincedb entry
          # see TODO in watch.rb
          watched_file.update_bytes_read(@sincedb[watched_file.inode])
        rescue EOFError
          listener.eof
          break
        rescue Errno::EWOULDBLOCK, Errno::EINTR
          listener.error
          break
        rescue => e
          @logger.debug? && @logger.debug("observe_read_file: general error reading #{watched_file.path} - error: #{e.inspect}")
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

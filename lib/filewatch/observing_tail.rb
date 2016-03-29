require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class ObservingTail
    include TailBase
    public

    def subscribe(observer = NullObserver.new)
      @watch.subscribe(@opts[:stat_interval],
                       @opts[:discover_interval]) do |event, watched_file|
        path = watched_file.path
        file_is_open = watched_file.file_open?
        listener = observer.listener_for(path)
        @logger.debug? && @logger.debug("subscribe block - #{event} for #{path}")
        case event
        when :unignore
          if !@sincedb.member?(watched_file.storage_key) && !file_is_open && _open_file(watched_file, event)
            listener.created
          end
        when :create, :create_initial
          if file_is_open
            @logger.debug? && @logger.debug("#{event} for #{path}: file already open")
            next
          end
          if _open_file(watched_file, event)
            listener.created
            observe_read_file(watched_file, listener)
          end
        when :grow, :shrink
          if file_is_open
            observe_read_file(watched_file, listener)
          else
            @logger.debug? && @logger.debug(":#{event} for #{path}, from empty file is not open, opening now")
            # it was grown from empty
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
          @sincedb.deallocate(watched_file)
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
      @sincedb.write("shutting down")
    end # def subscribe

    private

    def observe_read_file(watched_file, listener)
      changed = false
      @opts[:read_iterations].times do
        begin
          data = watched_file.file_read(FILE_READ_SIZE)
          changed = true
          watched_file.buffer_extract(data).each do |line|
            listener.accept(line)
            @sincedb.increment(watched_file.storage_key, line.bytesize + @delimiter_byte_size)
          end
        rescue EOFError
          listener.eof
          break
        rescue Errno::EWOULDBLOCK, Errno::EINTR
          listener.error
          break
        rescue => e
          @logger.error("observe_read_file: general error reading #{watched_file.path} - error: #{e.inspect}")
          listener.error
          break
        end
      end

      @sincedb.write_periodically if changed
    end # def _read_file
  end
end # module FileWatch

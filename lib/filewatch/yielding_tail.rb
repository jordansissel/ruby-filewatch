module FileWatch
  module YieldingTail
    public
    def yield_subscribe(&block)
      # subscribe(stat_interval = 1, discover_interval = 5, &block)
      @watch.subscribe(@opts[:stat_interval],
                       @opts[:discover_interval]) do |event, path|
        case event
        when :create, :create_initial
          if @files.member?(path)
            @logger.debug? && @logger.debug("#{event} for #{path}: already exists in @files")
            next
          end
          if _open_file(path, event)
            yield_read_file(path, &block)
          end
        when :modify
          if !@files.member?(path)
            @logger.debug? && @logger.debug(":modify for #{path}, does not exist in @files")
            if _open_file(path, event)
              yield_read_file(path, &block)
            end
          else
            yield_read_file(path, &block)
          end
        when :delete
          @logger.debug? && @logger.debug(":delete for #{path}, deleted from @files")
          if @files[path]
            yield_read_file(path, &block)
            @files[path].close
          end
          @files.delete(path)
          @statcache.delete(path)
        else
          @logger.warn("unknown event type #{event} for #{path}")
        end
      end # @watch.subscribe
    end # def subscribe

    private
    def yield_read_file(path, &block)
      @buffers[path] ||= FileWatch::BufferedTokenizer.new(@opts[:delimiter])
      delimiter_byte_size = @opts[:delimiter].bytesize
      changed = false
      loop do
        begin
          data = @files[path].sysread(32768)
          changed = true
          @buffers[path].extract(data).each do |line|
            yield(path, line)
            @sincedb[@statcache[path]] += (line.bytesize + delimiter_byte_size)
          end
        rescue Errno::EWOULDBLOCK, Errno::EINTR, EOFError
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
  end # module YieldingTail
end # module FileWatch

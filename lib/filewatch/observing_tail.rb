require 'filewatch/tail_base'
require 'rest-client'

module FileWatch
  class ObservingTail
    include TailBase
    public

    class NullListener
      def initialize(path)
        @path = path;
      end

      def accept(line)
      end

      def deleted()
      end

      def created()
      end

      def error()
      end

      def eof()
      end

      def timed_out()
      end
    end

    class NullObserver
      def listener_for(path)
        NullListener.new(path);
      end
    end

    def subscribe(observer = NullObserver.new)
      @watch.subscribe(@opts[:stat_interval],
                       @opts[:discover_interval]) do |event, watched_file|
        path = watched_file.path
        file_is_open = watched_file.file_open?
        listener = observer.listener_for(path)


        # ----------------------------------------------------------------------------------
        # Code modification to validate the file's MD5 Digest against a validation endpoint
        # ----------------------------------------------------------------------------------
        # check if an authentication endpoint is provided for the watch object
        if !@watch.auth_endpoint.nil?
          auth_endpoint = @watch.auth_endpoint
          @logger.debug? && @logger.debug("An authentication endpoint was found for file validation: #{auth_endpoint}")

          file_digest = Digest::MD5.file path
          md5_hex_digest = file_digest.hexdigest
          @logger.debug? && @logger.debug("Checksum MD5: #{md5_hex_digest} for file at path: #{path}")

          url = auth_endpoint
          query_string = "?md5="+md5_hex_digest

          # check for other params and append them as query/path parameters accordingly
          if !@watch.auth_params.nil?
            @watch.auth_params.each { |param|
              if param.include? "="
                query_string += ("&"+param)
              else
                url += param
              end
            }

            url += query_string
            @logger.debug? && @logger.debug("Final validation URL: #{url}")
          else
            url += query_string
            @logger.debug? && @logger.debug("No additional params found. Final validation URL: #{url}")
          end

          begin
            response = RestClient.get(url)
            @logger.debug? && @logger.debug("Response from validation endpoint: #{response.body}")
          rescue RestClient::ExceptionWithResponse => err
            @logger.warn("An invalid file at path - #{path} has the validation response: #{err.response}")
            @logger.debug? && @logger.debug("Response from validation endpoint: #{err.response}")
            watched_file.unwatch
          end
        end
        # ----------------------------------------------------------------------------------
        #                                   End of Modifications
        # ----------------------------------------------------------------------------------
        # continue processing only if the file status has not been changed to ":unwatched" as
        # result of failed validation above.

        if !(watched_file.state == :unwatched)
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
        end
      end # @watch.subscribe
      # when watch.subscribe ends - its because we got quit
      _sincedb_write
    end

    # def subscribe

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

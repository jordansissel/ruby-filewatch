#!/usr/bin/env ruby
# encoding: UTF-8

require "filewatch/tail"
require 'zlib'

module FileWatch
  class Gzip < Tail

    # Public: Initialize a new FileWatch::Gzip object
    #
    # opts - An options hash (default: {})
    #        :sincedb_write_interval - The Integer in seconds write to database (default: 10)
    #        :stat_interval - The Integer in seconds to sleep inbetween stat checks (default: 1)
    #        :discover_interval - The Integer in seconds to wait between globs (default: 5)
    #        :exclude - The array of Strings to exclude from glob check (default: [])
    #
    # Examples
    #
    #   FileWatch::Gzip.new({:discover_interval => 10, :exclude => ['/tmp/*']})
    #
    def initialize(opts = {})
      opts[:start_new_files_at] = :beginning
      super(opts)
    end
    
    # Public: Watch a path for new gzipped files
    #
    # path - The String glob expression to watch for gzipped files
    #
    # Returns true if successfull, false otherwise
    #
    # Examples
    #
    #   gz = FileWatch::Gzip.new
    #   gz.watch('/tmp/*gz') # => true
    #
    alias_method :watch, :tail

    public
    # Public: Initiates the loop that watches for files. Takes a block.
    #
    # block - Mandatory block. It will be sent the path to a file and a line
    #         from that file.
    #
    # Yields - The path of a file, and a line within that file
    #
    # Examples
    #
    #   gz = FileWatch::Gzip.new
    #   gz.watch('/tmp/*gz')
    #   gz.subscribe{|path, line| puts "#{path}:#{line}"}
    #
    # Returns nothing. Runs infinitely.
    #
    def subscribe(&block)
      @watch.subscribe(@opts[:stat_interval],
                       @opts[:discover_interval]) do |event, path|
        @logger.debug("#{self.class}#subscribe"){"Event: #{event} Path: #{path}"}

        case event
        when :create, :create_initial
          if @files.member?(path)
            @logger.debug("#{self.class}#subscribe"){"#{event} for #{path}: already exists in @files"}
            next
          end
          if _open_file(path, event)
            _read_file(path, &block)
          end
        when :modify
          if !@files.member?(path)
            @logger.debug(":modify for #{path}, does not exist in @files")
          end
        when :delete
          @logger.debug(":delete for #{path}, deleted from @files")
          @files[path].close
          @files.delete(path)
          @statcache.delete(path)
        else
          @logger.warn("unknown event type #{event} for #{path}")
        end

      end # @watch.subscribe
    end # def subscribe

    private
    def _read_file(path, &block)
      begin
        changed = false
        @logger.debug("#{self.class}#_read_file"){"GzipReader on #{path}"}
        gz = Zlib::GzipReader.new(@files[path])
        gz.each_line do |line|
          changed = true
          yield(path, line)
        end
        @sincedb[@statcache[path]] = @files[path].pos

        if changed
          now = Time.now.to_i
          delta = now - @sincedb_last_write
          if delta >= @opts[:sincedb_write_interval]
            @logger.debug("writing sincedb (delta since last write = #{delta})")
            _sincedb_write
            @sincedb_last_write = now
          end
        end
      rescue Zlib::Error, Zlib::GzipFile::Error, Zlib::GzipFile::NoFooter, Zlib::GzipFile::CRCError, Zlib::GzipFile::LengthError => e
        @logger.debug("#{self.class}#_read_file"){"#{e.class}:#{e.message} path:#{path}"}
      ensure
        gz.close unless gz.nil?
      end
    end # _read_file

  end # class Gzip
end # module FileWatch

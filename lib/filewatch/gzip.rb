#!/usr/bin/env ruby
# encoding: UTF-8

require "filewatch/tail"
require 'zlib'

module FileWatch
  class Gzip < Tail

    def initialize(opts = {})
      opts[:start_new_files_at] = :beginning
      super(opts)
    end

    public
    ##
    # yields |path, line| to block
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
        @logger.debug("#{self.class}#_read_file"){"GzipReader on #{path}"}
        gz = Zlib::GzipReader.new(@files[path])
        gz.each_line{|line| yield(path, line)}
      rescue Zlib::Error, Zlib::GzipFile::Error, Zlib::GzipFile::NoFooter, Zlib::GzipFile::CRCError, Zlib::GzipFile::LengthError => e
        @logger.debug("#{self.class}#_read_file"){"#{e.class}:#{e.message} path:#{path}"}
      ensure
        gz.close
      end

    end # _read_file

  end # class Gzip
end # module FileWatch

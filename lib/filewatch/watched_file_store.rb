require "filewatch/helper"
require_relative 'watched_file_comparator'
require "rbconfig"

if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
  require "filewatch/winhelper"
end

include Java if defined? JRUBY_VERSION
require "JRubyFileExtension.jar" if defined? JRUBY_VERSION

module FileWatch
  class WatchedFileStore
    attr_accessor :logger

    def initialize(max_active, sincedb_path, loggr)
      @iswindows = ((RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/) != nil)
      @store = Hash.new
      @lock = Mutex.new
      @max_active = max_active
      @comparator = WatchedFileComparator.new

      @sincedb_last_write = 0
      @sincedb_write_interval = 10
      @sincedb_path = sincedb_path
      @logger = loggr
      _sincedb_open
    end

    def upsert(wf)
      synchronized do
        merge_store(wf)
      end
    end

    def take_snapshot
      @snapshot = @store.values
    end

    def clear_snapshot
      @snapshot.clear
      @snapshot = nil
    end

    def select(selector)
      snapshot.select{|wf| wf.send(selector)}.each do |wf|
        yield wf
      end
      0
    end

    def max_select(take_selector, selector)
      if (to_take = @max_active - snapshot.count{|wf| wf.send(take_selector)}) > 0
        snapshot.select {|wf| wf.send(selector) }.take(to_take).each do |wf|
          yield wf
        end
        0
      else
        # return how many could not be taken
        snapshot.size - @max_active
      end
    end

    def find(key, value)
      synchronized do
        @store.select do |k, v|
          v.send(key) == value
        end.values
      end
    end

    def close
      sincedb_write("closing")
      @store.clear
    end

    def size
      @store.size
    end

    def sincedb_write(reason=nil)
      logger.debug? && logger.debug("caller requested sincedb write (#{reason})")
      _sincedb_write
    end

    def periodic_sincedb_write
      now = Time.now.to_i
      delta = now - @sincedb_last_write
      if delta >= @sincedb_write_interval
        logger.debug? && logger.debug("writing sincedb (delta since last write = #{delta})")
        _sincedb_write
        @sincedb_last_write = now
      end
    end

    private

    def _find(key, value)
      @store.select do |k, v|
        v.send(key) == value
      end.values
    end

    def _find_loaded(key, value)
      @store.select do |k, v|
        !v.discovered? && v.send(key) == value
      end.values
    end

    def merge_store(wf)
      same_inodes = _find_loaded(:raw_inode, wf.raw_inode)
      same_paths = _find_loaded(:path, wf.path)
      sames = (same_inodes & same_paths)
      return update_same(wf, sames) if sames.any?
      same_paths -= sames
      return update_same_path(wf, same_paths) if same_paths.any?
      same_inodes -= sames
      return update_same_inode(wf, same_inodes) if same_inodes.any?
      @store[wf.storage_key] = wf
    end

    def update_same_inode(new_wf, sames)
      existing = sames.pop
      # same inode different path
      # file was renamed? is it legacy?
      compared = @comparator.compare_inode_same(new_wf, existing)
      case compared
      when :same, :same_more_content, :same_less_content,
            :same_newer, :same_older, :unsure
        old_key = existing.storage_key.dup
        @store.delete(old_key)
        existing.update_path(new_wf.path)
        existing.update_stat(new_wf.filestat)
        @store[existing.storage_key] = existing
      when :legacy
        # treat same inode as the same file, use new, remove legacy transfer bytes read
        unless new_wf.last_stat_size < existing.bytes_read
          # treat as same (legacy behaviour)
          new_wf.update_bytes_read(existing.bytes_read)
        end
        @store[new_wf.storage_key] = new_wf
        @store.delete(existing.storage_key)
      when :newer, :newer_more_content, :newer_less_content, :less_content, :more_content,
            :older, :older_more_content, :older_less_content
        # treat as new
        @store[new_wf.storage_key] = new_wf
        @store.delete(existing.storage_key)
      else
        logger.warn("update_same_inode - got unexpected compare: #{compared}")
      end
      # delete any others
      sames.each do |wf|
        @store.delete(wf.storage_key)
      end
    end

    def update_same_path(new_wf, sames)
      existing = sames.pop
      # same path different inode
      compared = @comparator.compare_path_same(new_wf, existing)
      case compared
      when :same, :same_more_content, :same_less_content,
            :same_newer, :same_older, :unsure
        old_key = existing.storage_key.dup
        @store.delete(old_key)
        existing.update_inode(new_wf.inode)
        existing.update_stat(new_wf.filestat)
        @store[existing.storage_key] = existing
      when :newer, :older, :more_content, :less_content, :similar
        @store[new_wf.storage_key] = new_wf
        @store.delete(existing.storage_key)
      else
        logger.warn(" update_same_path - got unexpected compare: #{compared}")
      end
      # delete any others
      sames.each do |wf|
        @store.delete(wf.storage_key)
      end
    end

    def update_same(new_wf, sames)
      existing = sames.pop
      # is it the same file with the same content?
      # well if we are here then the path and inode are the same
      compared = @comparator.compare_path_inode_same(new_wf, existing)
      case compared
      when :same, :same_more_content, :older, :unsure
        # discard discovered file if:
        #   it is older than the one we had
        #   we are unsure (rare)
        #   it is the same
        existing.update_stat(new_wf.filestat)
       when :newer, :same_less_content
        # replace existing with discovered if:
        #    it is created more recently
        #    it is the same file but has less content than before
        @store[new_wf.storage_key] = new_wf
        if new_wf.storage_key != existing.storage_key
          # remove existing
          @store.delete(existing.storage_key)
        end
      else
        logger.warn("update_same - got unexpected compare: #{compared}")
      end
      # delete any others
      sames.each do |wf|
        @store.delete(wf.storage_key)
      end
    end

    def synchronized(&block)
      @lock.synchronize { block.call }
    end

    def snapshot
      @snapshot || []
    end

    def _sincedb_open
      path = @sincedb_path
      begin
        File.open(path) do |db|
          logger.debug? && logger.debug("_sincedb_open: reading from #{path}")
          db.each do |line|
            if (wf = WatchedFile.deserialize(line.chomp))
              logger.debug? && logger.debug("_sincedb_open: setting #{wf.storage_key} to #{wf.bytes_read}")
              @store[wf.storage_key] = wf
            end
          end
        end
      rescue
        #No existing sincedb to load
        logger.debug? && logger.debug("_sincedb_open: error: #{path}: #{$!}")
      end
    end

    def _sincedb_write
      path = @sincedb_path
      begin
        if @iswindows || File.device?(path)
          IO.write(path, serialize_sincedb, 0)
        else
          File.write_atomically(path) do |file|
            # try not to build a huge string
            @store.each do |key, wf|
              file.puts(wf.serialize)
            end
          end
        end
      rescue Errno::EACCES
        # probably no file handles free
        # maybe it will work next time
        logger.debug? && logger.debug("_sincedb_write: error: #{path}: #{$!}")
      end
    end

    def serialize_sincedb
      # for windows only - build big string
      @store.map do |key, wf|
        wf.serialize
      end.join("\n") + "\n"
    end
  end
end

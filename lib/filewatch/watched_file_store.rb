require_relative 'watched_file_comparator'

module FileWatch
  class WatchedFileStore
    def initialize(max_active)
      @store = Hash.new
      @lock = Mutex.new
      @max_active = max_active
      @comparator = WatchedFileComparator.new
    end

    def upsert(wf)
      synchronized do
        merge_store(wf)
      end
    end

    def merge_store(wf)
      same_inodes = find(:raw_inode, wf.raw_inode)
      same_paths = find(:path, wf.path)
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
      # file was renamed?
      compared = @comparator.compare_inode_same(new_wf, existing)
      case compared
      when :same, :same_more_content, :unsure
        old_key = existing.storage_key.dup
        @store.delete(old_key)
        existing.update_path(new_wf.path)
        @store[existing.storage_key] = existing
      when :same_less_content, :newer, :newer_more_content, :newer_less_content,
        :older, :older_more_content, :older_less_content
        # treat as new
        @store[new_wf.storage_key] = new_wf
        @store.delete(existing.storage_key)
      end
    end

    def update_same_path(new_wf, sames)
      existing = sames.pop
      # same path different inode
      compared = @comparator.compare_path_same(new_wf, existing)
      case compared
      when :same, :same_more_content, :older, :unsure
        old_key = existing.storage_key.dup
        @store.delete(old_key)
        existing.update_inode(new_wf.inode)
        @store[existing.storage_key] = existing
      when :newer, :same_less_content
        @store[new_wf.storage_key] = new_wf
        @store.delete(existing.storage_key)
      end
      # delete any others
      sames.each do |wf|
        @store.delete(wf.storage_key)
      end
    end

    def update_same(new_wf, sames)
      existing = sames.last
      # is it the same file with the same content?
      # well if we are here then the path and inode are the same
      compared = @comparator.compare_path_inode_same(new_wf, existing)
      case compared
      when :same, :same_more_content, :older, :unsure
        # discard discovered file if:
        #   it is older than the one we had
        #   we are unsure (rare)
        #   it is the same
        return
      when :newer, :same_less_content
        # replace existing with discovered if:
        #    it is created more recently
        #    it is the same file but has less content than before
        @store[new_wf.storage_key] = new_wf
        if new_wf.storage_key != existing.storage_key
          # remove existing
          @store.delete(existing.storage_key)
        end
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

    private

    def synchronized(&block)
      @lock.synchronize { block.call }
    end

    def snapshot
      @snapshot || []
    end
  end
end

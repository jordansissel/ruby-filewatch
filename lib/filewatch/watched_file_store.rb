module FileWatch
  class WatchedFileStore
    def initialize(max_active)
      @store = Hash.new
      @lock = Mutex.new
      @max_active = max_active
    end

    def store(wf)
      k = "#{wf.inode.first}|#{wf.path}"
      synchronized do
        @store[k] = wf
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

require "filewatch/buftok"

module FileWatch
  class WatchedFile
    def self.new_initial(path, inode, stat = nil)
      new(path, inode, stat, true)
    end

    def self.new_ongoing(path, inode, stat = nil)
      new(path, inode, stat, false)
    end

    attr_reader :size, :inode, :state, :file, :buffer, :state_history
    attr_reader :path, :filestat, :ignored_size, :accessed_at
    attr_accessor :close_older, :ignore_older, :delimiter

    def delimiter
      @delimiter
    end

    def initialize(path, inode, stat, initial)
      @path = path
      @ignored_size = @size = 0
      @inode = inode
      @initial = initial
      @state_history = []
      @state = :watched
      if (@filestat = stat).nil? && !@inode.nil?
        restat
      end
      set_accessed_at
    end

    def set_accessed_at
      @accessed_at = Time.now.to_i
    end

    def initial?
      @initial
    end

    def size_changed?
      filestat.size != size
    end

    def inode_changed?(value)
      self.inode != value
    end

    def file_add_opened(rubyfile)
      @file = rubyfile
      @buffer = FileWatch::BufferedTokenizer.new(delimiter || "\n")
    end

    def file_close
      return if @file.nil? || @file.closed?
      @file.close
      @file = nil
    end

    def file_seek(amount, whence = IO::SEEK_SET)
      @file.sysseek(amount, whence)
    end

    def file_read(amount)
      set_accessed_at
      @file.sysread(amount)
    end

    def file_open?
      !@file.nil? && !@file.closed?
    end

    def update_read_size(total_bytes_read)
      return if total_bytes_read.nil?
      @size = total_bytes_read
    end

    def buffer_extract(data)
      @buffer.extract(data)
    end

    def update_inode(_inode)
      @inode = _inode
    end

    def update_size
      @size = @filestat.size
    end

    def activate
      archive_state
      @state = :active
    end

    def ignore
      archive_state
      @state = :ignored
      @ignored_size = @size = @filestat.size
    end

    def close
      archive_state
      @state = :closed
    end

    def watch
      archive_state
      @state = :watched
    end

    def unwatch
      archive_state
      @state = :unwatched
    end

    def active?
      @state == :active
    end

    def ignored?
      @state == :ignored
    end

    def closed?
      @state == :closed
    end

    def watched?
      @state == :watched
    end

    def unwatched?
      @state == :unwatched
    end

    def expiry_close_enabled?
      !@close_older.nil?
    end

    def expiry_ignore_enabled?
      !@ignore_older.nil?
    end

    def restat
      @filestat = File::Stat.new(path)
    end

    def archive_state
      @state_history << @state
    end

    def state_history_any?(*previous)
      (@state_history & previous).any?
    end

    def file_closable?
      file_can_close? && !size_changed?
    end

    def file_ignorable?
      return false unless expiry_ignore_enabled?
      # (Time.now - stat.mtime) <- in jruby, this does int and float
      # conversions before the subtraction and returns a float.
      # so use all ints instead
      (Time.now.to_i - filestat.mtime.to_i) > ignore_older
    end

    def file_can_close?
      return false unless expiry_close_enabled?
      # (Time.now - @open_at) <- in jruby, this does int and float
      # conversions before the subtraction and returns a float.
      # so use all ints instead
      # (Time.now.to_i - filestat.mtime.to_i) > close_older
      (Time.now.to_i - @accessed_at) > close_older
    end

    def to_s() inspect; end
  end
end

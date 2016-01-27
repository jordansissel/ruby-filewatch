require "filewatch/buftok"

module FileWatch
  class WatchedFile
    def self.new_initial(path, inode, stat)
      new(path, inode, stat, true)
    end

    def self.new_ongoing(path, inode, stat)
      new(path, inode, stat, false)
    end

    attr_reader :bytes_read, :inode, :state, :file, :buffer, :state_history
    attr_reader :path, :filestat, :accessed_at
    attr_accessor :close_older, :ignore_older, :delimiter

    def delimiter
      @delimiter
    end

    def initialize(path, inode, stat, initial)
      @path = path
      @bytes_read = 0
      @inode = inode
      @initial = initial
      @state_history = []
      @state = :watched
      @filestat = stat
      set_accessed_at
    end

    def init_vars(delim, ignore_o, close_o)
      @delimiter = delim
      @ignore_older = ignore_o
      @close_older = close_o
      self
    end

    def set_accessed_at
      @accessed_at = Time.now.to_f
    end

    def initial?
      @initial
    end

    def size_changed?
      filestat.size != bytes_read
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

    def update_bytes_read(total_bytes_read)
      return if total_bytes_read.nil?
      @bytes_read = total_bytes_read
    end

    def buffer_extract(data)
      @buffer.extract(data)
    end

    def update_inode(_inode)
      @inode = _inode
    end

    def activate
      set_state :active
    end

    def ignore
      set_state :ignored
      @bytes_read = @filestat.size
    end

    def close
      set_state :closed
    end

    def watch
      set_state :watched
    end

    def unwatch
      set_state :unwatched
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

    def set_state(value)
      @state_history << @state
      @state = value
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
      # so use all floats upfront
      (Time.now.to_f - filestat.mtime.to_f) > ignore_older
    end

    def file_can_close?
      return false unless expiry_close_enabled?
      (Time.now.to_f - @accessed_at) > close_older
    end

    def to_s() inspect; end
  end
end

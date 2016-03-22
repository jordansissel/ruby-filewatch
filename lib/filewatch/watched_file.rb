require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class WatchedFile
    def self.new_initial(path, inode, stat)
      new(path, inode, stat, true).from_discover
    end

    def self.new_ongoing(path, inode, stat)
      new(path, inode, stat, false).from_discover
    end

    attr_reader :bytes_read, :inode, :state, :file, :buffer, :state_history
    attr_reader :path, :filestat, :accessed_at, :modified_at, :fingerprints
    attr_reader :storage_key, :last_stat_size, :bytes_read_digest
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
      @fingerprints = []
      set_stat(stat)
      get_fingerprints
      set_storage_key
      set_accessed_at
    end

    def init_vars(delim, ignore_o, close_o)
      @delimiter = delim
      @ignore_older = ignore_o
      @close_older = close_o
      self
    end

    def add_bytes_read_digest(hd)
      @bytes_read_digest = hd
    end

    # subclass may override
    def compute_storage_key
      "#{path}|#{sdb_key_v1}"
    end

    def sdb_key_v1
      @inode.join(" ")
    end

    def sdb_key_v2
      @storage_key
    end

    def set_storage_key
      @storage_key = compute_storage_key
    end

    def from_discover
      @discovered = true
      self
    end

    def from_sincedb
      @discovered = false
      self
    end

    def set_accessed_at
      @accessed_at = Time.now.to_f
    end

    def discovered?
      @discovered
    end

    def initial?
      @initial
    end

    def size_changed?
      @last_stat_size != bytes_read
    end

    def file_add_opened(rubyfile)
      @file = rubyfile
      @buffer = BufferedTokenizer.new(delimiter || "\n")
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

    def buffer_extract(data)
      @buffer.extract(data)
    end

    def update_bytes_read(total_bytes_read)
      return if total_bytes_read.nil?
      @bytes_read = total_bytes_read
    end

    def update_inode(_inode)
      @inode = _inode
      set_storage_key
      @inode
    end

    def update_path(_path)
      @path = _path
      set_storage_key
      @path
    end

    def update_stat(st)
      set_stat(st)
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
      set_stat(File::Stat.new(path))
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
      (Time.now.to_f - @modified_at) > ignore_older
    end

    def file_can_close?
      return false unless expiry_close_enabled?
      (Time.now.to_f - @accessed_at) > close_older
    end

    def inode_changed?(value)
      self.inode != value
    end

    def to_s() inspect; end

    def raw_inode
      @raw_inode ||= @inode.first
    end

    def serialize
      "#{path} #{raw_inode} #{bytes_read} #{modified_at} #{last_stat_size} #{state} #{state_history.join(',')}"
    end

    private

    def get_fingerprints
      # if a new truncated file is discovered before content is added
      # defer the fingerprinting till later
      return if @last_stat_size == 0
      begin
        file = FileOpener.open(@path)
        [0, compute_last_fp_offset].compact.each do |offset|
          @fingerprints << Fingerprinter.new(@path, offset).read_file(file)
        end
      rescue => e
        # log the error
      ensure
        file.close if !file.nil?
      end
    end

    def compute_last_fp_offset
      return if @last_stat_size < FP_BYTE_SIZE
      return if @read_blocks == 0
      @read_blocks * FILE_READ_SIZE
    end

    def set_stat(stat)
      @last_stat_size = stat.size
      @modified_at = stat.mtime.to_f
      @read_blocks, @last_read_block_size = @last_stat_size.divmod(FILE_READ_SIZE)
      @filestat = stat
    end
  end
end

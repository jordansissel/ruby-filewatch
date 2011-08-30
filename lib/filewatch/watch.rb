require "logger"

module FileWatch
  class Watch
    attr_accessor :logger

    public
    def initialize(opts={})
      @logger = Logger.new(STDERR)
      @watching = []
      @files = Hash.new { |h, k| h[k] = Hash.new }
    end # def initialize

    public
    def logger=(logger)
      @logger = logger
    end

    # TODO(petef): support excludes

    public
    def watch(path)
      if ! @watching.member?(path)
        @watching << path
        _discover_file(path, true)
      end

      return true
    end # def tail

    # Calls &block with params [event_type, path]
    # event_type can be one of:
    #   :create_initial - initially present file (so start at end for tail)
    #   :create - file is created (new file after initial globs, start at 0)
    #   :modify - file is modified (size increases)
    #   :delete - file is deleted
    public
    def each(&block)
      # Send any creates.
      @files.keys.each do |path|
        if ! @files[path][:create_sent]
          if @files[path][:initial]
            yield(:create_initial, path)
          else
            yield(:create, path)
          end
          @files[path][:create_sent] = true
        end
      end

      @files.keys.each do |path|
        begin
          stat = File::Stat.new(path)
        rescue Errno::ENOENT
          # file has gone away or we can't read it anymore.
          @files.delete(path)
          @logger.debug("#{path}: stat failed (#{$!}), deleting from @files")
          yield(:delete, path)
          next
        end

        inode = [stat.ino, stat.dev_major, stat.dev_minor]
        if inode != @files[path][:inode]
          @logger.debug("#{path}: old inode was #{@files[path][:inode].inspect}, new is #{inode.inspect}")
        elsif stat.size < @files[path][:size]
          @logger.debug("#{path}: file rolled, new size is #{stat.size}, old size #{@files[path][:size]}")
          yield(:delete, path)
          yield(:create, path)
        elsif stat.size > @files[path][:size]
          @logger.debug("#{path}: file grew, old size #{@files[path][:size]}, new size #{stat.size}")
          yield(:modify, path)
        end

        @files[path][:size] = stat.size
        @files[path][:inode] = inode
      end # @files.keys.each
    end # def each

    public
    def discover
      @watching.each do |path|
        _discover_file(path)
      end
    end

    public
    def subscribe(stat_interval = 1, discover_interval = 5, &block)
      glob = 0
      loop do
        each(&block)

        glob += 1
        if glob == discover_interval
          discover
          glob = 0
        end

        sleep(stat_interval)
      end
    end # def subscribe

    private
    def _discover_file(path, initial=false)
      Dir.glob(path).each do |file|
        next if @files.member?(file)
        next unless File.file?(file)

        @logger.debug("_discover_file: #{path}: new: #{file}")
        stat = File::Stat.new(file)
        @files[file] = {
          :size => 0,
          :inode => [stat.ino, stat.dev_major, stat.dev_minor],
          :create_sent => false,
        }
        if initial
          @files[file][:initial] = true
        end
      end
    end # def _discover_file

  end # class Watch
end # module FileWatch

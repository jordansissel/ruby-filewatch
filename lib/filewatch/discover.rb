require_relative 'watched_file'

module FileWatch
  class Discover
    attr_reader  :logger, :files, :wf_vars

    def initialize(opts, loggr)
      @logger = loggr
      @watching = []
      @exclude = []
      @files = {}
      set_ignore_older(opts[:ignore_older])
      set_close_older(opts[:close_older])
      @wf_vars = [opts[:delimiter], @ignore_older, @close_older]
      exclude(opts[:exclude])
    end

    def logger=(loggr)
      @logger = loggr
      @converter.logger = loggr
    end

    def add_converter(converter)
      @converter = converter
    end

    def add_path(path)
      return if @watching.member?(path)
      @watching << path
      discover_file(path) do |fpath, stat|
        WatchedFile.new_initial(*wf_args(fpath, stat)).init_vars(*wf_vars)
      end
    end

    def discover
      @watching.each do |path|
        discover_file(path) do |fpath, stat|
          WatchedFile.new_ongoing(*wf_args(fpath, stat)).init_vars(*wf_vars)
        end
      end
    end

    def delete(paths)
      paths.each {|f| @files.delete(f)}
    end

    def close_all
      @files.values.each(&:file_close)
    end

    def empty?
      @files.empty?
    end

    def watched_files
      @files.values
    end

    private

    def set_ignore_older(value)
      #nil is allowed but 0 and negatives are made nil
      if !value.nil?
        val = value.to_f
        val = val <= 0 ? nil : val
      end
      @ignore_older = val
    end

    def set_close_older(value)
      if !value.nil?
        val = value.to_f
        val = val <= 0 ? nil : val
      end
      @close_older = val
    end

    def exclude(path)
      path.to_a.each { |p| @exclude << p }
    end

    def wf_args(path, stat)
      [path, stat]
    end

    def file_lookup(path)
      @files[path]
    end

    def discover_file(path)
      globbed_files(path).each do |file|
        next unless File.file?(file)
        new_discovery = false
        watched_file = file_lookup(file)
        if watched_file.nil?
          @logger.debug? && @logger.debug("_discover_file: #{path}: new: #{file} (exclude is #{@exclude.inspect})")
          # let the caller build the object in its context
          new_discovery = true
          watched_file = yield(file, File::Stat.new(file))
        end

        skip = false
        @exclude.each do |pattern|
          if File.fnmatch?(pattern, File.basename(file))
            @logger.debug? && @logger.debug("_discover_file: #{file}: skipping because it " +
                          "matches exclude #{pattern}") if new_discovery
            skip = true
            watched_file.unwatch
            break
          end
        end
        next if skip

        if new_discovery
          if watched_file.file_ignorable?
            @logger.debug? && @logger.debug("_discover_file: #{file}: skipping because it was last modified more than #{@ignore_older} seconds ago")
            # on discovery we put watched_file into the ignored state and that
            # updates the size from the internal stat
            # so the existing contents are not read.
            # because, normally, a newly discovered file will
            # have a watched_file size of zero
            watched_file.ignore
          end
          @converter.convert_watched_file(watched_file) unless watched_file.unstorable?
          @files[file] = watched_file
        end
      end
    end

    def globbed_files(path)
      globbed_dirs = Dir.glob(path)
      @logger.debug? && @logger.debug("_globbed_files: #{path}: glob is: #{globbed_dirs}")
      if globbed_dirs.empty? && File.file?(path)
        globbed_dirs = [path]
        @logger.debug? && @logger.debug("_globbed_files: #{path}: glob is: #{globbed_dirs} because glob did not work")
      end
      # return Enumerator
      globbed_dirs.to_enum
    end
  end
end

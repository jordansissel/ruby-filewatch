# encoding: utf-8
require_relative 'watched_file'

module FileWatch
  class Discover
    attr_reader  :logger, :files, :watched_file_config

    def initialize(opts, loggr)
      @logger = loggr
      @watching = []
      @exclude = []
      @files = {}
      @watched_file_config = WatchedFileConfig.new(
        *opts.values_at(:delimiter, :close_older, :ignore_older)
      )
      exclude(opts[:exclude])
    end

    def logger=(loggr)
      @logger = loggr
      @converter.logger = loggr
    end

    def add_converter(converter)
      @converter = converter
      self
    end

    def add_path(path)
      return if @watching.member?(path)
      @watching << path
      discover_file(path) do |fpath, stat|
        WatchedFile.new_initial(fpath, stat).add_config(@watched_file_config)
      end
      self
    end

    def discover
      @watching.each do |path|
        discover_file(path) do |fpath, stat|
          WatchedFile.new_ongoing(fpath, stat).add_config(@watched_file_config)
        end
      end
    end

    def delete(paths)
      Array(paths).each {|f| @files.delete(f)}
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


    def exclude(paths)
      paths.to_a.each { |p| @exclude << p }
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
          @logger.debug? && @logger.debug("discover_file: #{path}: new: #{file} (exclude is #{@exclude.inspect})")
          # let the caller build the object in its context
          new_discovery = true
          watched_file = yield(file, File::Stat.new(file))
        end
        # if it already unwatched or its excluded then we can skip
        next if watched_file.unwatched? || exclude?(watched_file, new_discovery)

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

    def exclude?(watched_file, new_discovery)
      skip = false
      file_basename = File.basename(watched_file.path)
      @exclude.each do |pattern|
        if File.fnmatch?(pattern, file_basename)
          if new_discovery && @logger.debug?
            @logger.debug("_discover_file: #{watched_file.path}: skipping " +
              "because it matches exclude #{pattern}")
          end
          skip = true
          watched_file.unwatch
          break
        end
      end
      skip
    end

    def globbed_files(path)
      globbed_dirs = Dir.glob(path)
      @logger.debug? && @logger.debug("globbed_files: #{path}: glob is: #{globbed_dirs}")
      if globbed_dirs.empty? && File.file?(path)
        globbed_dirs = [path]
        @logger.debug? && @logger.debug("_globbed_files: #{path}: glob is: #{globbed_dirs} because glob did not work")
      end
      # return Enumerator
      globbed_dirs.to_enum
    end
  end
end

require "rubygems"
require "filewatch/watch"

watch = FileWatch::Watch.new
globdirs = []
watching = []
ARGV.each do |glob|
  # Watch every file found by a glob
  paths = Dir.glob(glob)
  paths.each do |path|
    begin
      #watch.watch(path, :create, :delete, :modify)
      watching << path
    rescue FileWatch::Exception => e
      $stderr.puts "Failed starting watch on #{path} - #{e}"
    end
  end

  splitpath = glob.split(File::SEPARATOR)
  splitpath.each_with_index do |part, i|
    current = File.join(splitpath[0 .. i])
    current = "/" if current.empty?
    next if watching.include?(current)
    # TODO(sissel): Do better glob detection
    if part.include?("*")
      path = File.join(splitpath[0 ... i])
      p "Watching dir #{path}"
      watch.watch(path, :create, :modify, :delete)
      globdirs << path
    end
  end
  # Watch any directory containing a glob in the next level
end

watch.subscribe do |event|
  puts event
end


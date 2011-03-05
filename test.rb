$: << "lib"

require "inotify/fd"
fd = Inotify::FD.new
p fd

paths = ARGV.clone

failures = 0
count = 0

while paths.size > 0
  path = paths.shift
  begin
    puts "Watching #{path}"
    fd.watch(path, :access, :create, :delete, :modify, :attrib, :move)
    count += 1
  rescue => e
    $stderr.puts e
    #$stderr.puts e.backtrace
    failures += 1
    if failures > 100
      puts "Failed too much. #{count} watches successful."
      break 2
    end
    next
  end

  next unless File.directory?(path)

  Dir.entries(path).each do |childpath|
    next if [".", ".."].include?(childpath)
    path = File.join(path, childpath)
    next if path[/^\/dev/]
    next if path[/^\/proc/]
    next if File.symlink?(path)
    if File.directory?(path)
      paths << path
    end
  end
end

loop do
  fd.read do |event|
    puts event
  end
end

require "rubygems"
require "filewatch/watch"

watch = FileWatch::Watch.new
ARGV.each do |path|
  watch.watch(path, :create, :delete, :modify)
end
watch.subscribe do |event|
  puts event
end


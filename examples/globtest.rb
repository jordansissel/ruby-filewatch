require "rubygems"
require "filewatch/watchglob"

watch = FileWatch::WatchGlob.new
ARGV.each do |glob|
  watch.watch(glob, :create, :modify, :delete)
end

watch.subscribe do |event|
  puts event
end

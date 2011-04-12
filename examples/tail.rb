require "rubygems"
require "filewatch/tail"
require "eventmachine" # for BufferedTokenizer

tail = FileWatch::Tail.new
ARGV.each do |path|
  tail.watch(path, :create, :delete, :modify)
end

b = BufferedTokenizer.new
tail.subscribe do |path, data|
  b.extract(data).each do |line|
    p path => line
  end
end


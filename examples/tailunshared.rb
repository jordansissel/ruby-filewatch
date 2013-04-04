require "rubygems"
require "filewatch/tail"
require "filewatch/buftok"

# Setting  CloseAfterRead will always close the 
# file being watched. This will allow the file
# to be deleted in Windows.
ENV['CloseAfterRead'] = "true"

tail = FileWatch::Tail.new
ARGV.each do |path|
  tail.tail(path)
end

b = FileWatch::BufferedTokenizer.new
tail.subscribe do |path, data|
  b.extract(data).each do |line|
    p path => line
  end
end


require "rubygems"
require "filewatch/tailglob"
require "eventmachine" # for BufferedTokenizer

tail = FileWatch::TailGlob.new
ARGV.each do |path|
  tail.tail(path)
end

b = BufferedTokenizer.new
tail.subscribe do |path, data|
  b.extract(data).each do |line|
    if ARGV.size == 1
      puts line
    else
      puts "#{path}: #{line}"
    end
  end
end


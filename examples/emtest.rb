require "rubygems"
require "eventmachine"
require "inotify/fd"

EventMachine.run do
  fd = Inotify::FD.new
  fd.watch("/tmp", :create, :delete)
  fd.subscribe do |event|
    puts event
  end
end

$: << "lib"

require "inotify/fd"
fd = Inotify::FD.new
p fd

fd.watch("/tmp", :attrib, :modify, :create, :delete)

loop do
  event = fd.read
  p event.name
  p event
end

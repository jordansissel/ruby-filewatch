# filewatch 

This project aims to provide file watching under any circumstances.

* inotify (works now)
* kqueue (needs to be implemented)
* stat polling (needs to be implemented)

Goals:

* to provide a rubyish api to inotify
* to integrate with eventmachine, replace current EM::watch_file and support
  directories and more.
* to still be useful outside EM
* to work in major rubies (mri, yarv, jruby, rubinius?)

Maybe:

* generate dtrace and systemtap scripts for watching activities on certain
  files/directories?

What works now:

* inotify (linux) watches in MRI 1.8.7, YARV 1.9.2, JRuby 1.6.0

Example code (standalone):

    require "rubygems"
    require "filewatch/watch"

    w = FileWatch::Watch.new
    w.watch("/tmp", :create, :deletE)
    w.subscribe do |event|
      puts event
    end

Example in EventMachine (no change; we are EM-aware):

    require "rubygems"
    require "eventmachine"
    require "filewatch/watch"

    EventMachine.run do
      w = FileWatch::Watch.new
      w.watch("/tmp", :create, :deletE)
      w.subscribe do |event|
        puts event
      end
    end

Example tool:

    % ruby test.rb /var/log
    Watching /var/log
    Watching /var/log/xen
    Watching /var/log/apparmor
    Watching /var/log/exim4
    Watching /var/log/ConsoleKit
    << Lots of files being watched, output trimmed .... >>

    Starting reads...
    Sat Mar 05 00:32:15 -0800 2011: /var/log/mysql/error.log (modify)
    Sat Mar 05 00:32:16 -0800 2011: /var/log/mysql/error.log (modify)
    Sat Mar 05 00:32:17 -0800 2011: /var/log/syslog (modify)
    Sat Mar 05 00:32:17 -0800 2011: /var/log/user.log (modify)
    Sat Mar 05 00:32:17 -0800 2011: /var/log/messages (modify)
    Sat Mar 05 00:32:17 -0800 2011: /var/log/messages (access)
    Sat Mar 05 00:32:17 -0800 2011: /var/log/mysql/error.log (modify)


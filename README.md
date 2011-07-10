# filewatch 

## Getting Started

* gem install filewatch
* globtail -x '*.gz' '/var/log/*'

For developers, see FileWatch::Watch, FileWatch::Tail, FileWatch::WatchGlob,
and FileWatch::TailGlob.

Supported platforms:

* JRuby
* MRI (without EventMachine)
* EventMachine/MRI

All operating systems should be supported.  Tested on Linux.

## Overview

This project provide file and glob watching.

Goals:

* to provide a rubyish api to get notifications of file or glob changes
* to work in major rubies (mri, yarv, jruby, rubinius?)

Example code (standalone):

    require "rubygems"
    require "filewatch/watchglob"

    w = FileWatch::WatchGlob.new
    w.watch("/tmp/*", :create, :delete)
    w.subscribe do |path, event|
      puts "#{event}: #{path}"
    end

# filewatch 

## Getting Started

* gem install filewatch
* globtail -x '*.gz' '/var/log/*'

For developers, see FileWatch::Watch and FileWatch::Tail.

Tested on Linux/x86_64.

All operating systems should be supported. If you run the tests on
another platform, please open a Github issue with the output (even
if it passes, so we can update this document).

## Overview

This project provide file and glob watching.

Goals:

* to provide a rubyish api to get notifications of file or glob changes
* to work in major rubies (mri, yarv, jruby, rubinius?)

Example code (standalone):

    require "rubygems"
    require "filewatch/tail"

    t = FileWatch::Tail.new
    t.tail("/tmp/test*.log")
    t.subscribe do |path, line|
      puts "#{path}: #{line}"
    end

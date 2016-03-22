package com.logstash.filewatch;

/**
 * Created with IntelliJ IDEA. User: efrey Date: 6/11/13 Time: 11:00 AM To
 * change this template use File | Settings | File Templates.
 *
 * http://bugs.sun.com/view_bug.do?bug_id=6357433
 * [Guy] modified original to be a proper JRuby class
 * [Guy] do we need this anymore? JRuby 1.7+ uses new Java 7 File API
 *
 *
 * fnv code extracted and modified from https://github.com/jakedouglas/fnv-java
 */

import org.jruby.*;
import org.jruby.anno.JRubyClass;
import org.jruby.anno.JRubyMethod;
import org.jruby.runtime.Arity;
import org.jruby.runtime.ObjectAllocator;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.runtime.load.Library;
import org.jruby.util.io.InvalidValueException;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.channels.Channel;
import java.nio.channels.FileChannel;
import java.nio.file.FileSystems;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

public class JrubyFileWatchLibrary implements Library {

    private static final BigInteger INIT32 = new BigInteger("811c9dc5", 16);
    private static final BigInteger INIT64 = new BigInteger("cbf29ce484222325", 16);
    private static final BigInteger PRIME32 = new BigInteger("01000193", 16);
    private static final BigInteger PRIME64 = new BigInteger("100000001b3", 16);
    private static final BigInteger MOD32 = new BigInteger("2").pow(32);
    private static final BigInteger MOD64 = new BigInteger("2").pow(64);

    @Override
    public void load(Ruby runtime, boolean wrap) throws IOException {
        RubyModule module = runtime.defineModule("FileWatch");
        RubyClass clazz;

        clazz = runtime.defineClassUnder("FileExt", runtime.getObject(), new ObjectAllocator() {
            @Override
            public IRubyObject allocate(Ruby runtime, RubyClass rubyClass) {
                return new RubyFileExt(runtime, rubyClass);
            }
        }, module);
        clazz.defineAnnotatedMethods(RubyFileExt.class);

        clazz = runtime.defineClassUnder("Fnv", runtime.getObject(), new ObjectAllocator() {
            @Override
            public IRubyObject allocate(Ruby runtime, RubyClass rubyClass) {
                return new Fnv(runtime, rubyClass);
            }
        }, module);
        clazz.defineAnnotatedMethods(Fnv.class);

    }

    @JRubyClass(name = "FileExt", parent = "Object")
    public static class RubyFileExt extends RubyObject {

        public RubyFileExt(Ruby runtime, RubyClass metaClass) {
            super(runtime, metaClass);
        }

        public RubyFileExt(RubyClass metaClass) {
            super(metaClass);
        }

        @JRubyMethod(name = "open", required = 1, meta = true)
        public static RubyIO open(ThreadContext context, IRubyObject self, RubyString path) throws IOException, InvalidValueException {
            Path p = FileSystems.getDefault().getPath(path.asJavaString());
            OpenOption[] options = new OpenOption[1];
            options[0] = StandardOpenOption.READ;
            Channel channel = FileChannel.open(p, options);
            return new RubyIO(Ruby.getGlobalRuntime(), channel);
        }
    }

    @JRubyClass(name = "Fnv", parent = "Object")
    public static class Fnv extends RubyObject {

        private byte[] bytes;
        private long size;
        private boolean open = false;

        public Fnv(Ruby runtime, RubyClass metaClass) {
            super(runtime, metaClass);
        }

        public Fnv(RubyClass metaClass) {
            super(metaClass);
        }

        // def initialize(data)
        @JRubyMethod(name = "initialize", required = 1)
        public IRubyObject ruby_initialize(ThreadContext ctx, RubyString data) {
            bytes = data.getBytes();
            size = bytes.length;
            open = true;
            return ctx.nil;
        }

        @JRubyMethod(name = "close")
        public IRubyObject close(ThreadContext ctx) {
            open = false;
            bytes = null;
            return ctx.nil;
        }

        @JRubyMethod(name = "open?")
        public IRubyObject open_p(ThreadContext ctx) {
            if(open) return ctx.runtime.getTrue();
            return ctx.runtime.getFalse();
        }

        @JRubyMethod(name = "closed?")
        public IRubyObject closed_p(ThreadContext ctx) {
            if(open) return ctx.runtime.getFalse();
            return ctx.runtime.getTrue();
        }

        @JRubyMethod(name = "fnv1a32", optional = 1)
        public IRubyObject fnv1a_32(ThreadContext ctx, IRubyObject[] args) {
            if(open) {
                args = Arity.scanArgs(ctx.runtime, args, 0, 1);
                return RubyBignum.newBignum(ctx.runtime, common_fnv(args[0], INIT32, PRIME32, MOD32));
            }
            throw ctx.runtime.newRaiseException(ctx.runtime.getClass("StandardError"), "Fnv instance is closed!");
        }

        @JRubyMethod(name = "fnv1a64", optional = 1)
        public IRubyObject fnv1a_64(ThreadContext ctx, IRubyObject[] args) {
            if(open) {
                args = Arity.scanArgs(ctx.runtime, args, 0, 1);
                return RubyBignum.newBignum(ctx.runtime, common_fnv(args[0], INIT64, PRIME64, MOD64));
            }
            throw ctx.runtime.newRaiseException(ctx.runtime.getClass("StandardError"), "Fnv instance is closed!");
        }

        private long convertLong(IRubyObject obj) {
            if(obj instanceof RubyInteger) {
                return ((RubyInteger)obj).getLongValue();
            }
            if(obj instanceof RubyFixnum) {
                return ((RubyFixnum)obj).getLongValue();
            }

            return size;
        }

        private BigInteger common_fnv(IRubyObject len, BigInteger hash, BigInteger prime, BigInteger mod) {
            BigInteger h = hash;
            long l = convertLong(len);

            if (l > size) {
                l = size;
            }

            for (int i = 0; i < l; i++) {
                h = h.xor(BigInteger.valueOf((int) bytes[i] & 0xff));
                h = h.multiply(prime).mod(mod);
            }

            return h;
        }
    }

}

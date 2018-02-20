package org.logstash.filewatch;

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

import org.jruby.Ruby;
import org.jruby.RubyBignum;
import org.jruby.RubyClass;
import org.jruby.RubyFixnum;
import org.jruby.RubyIO;
import org.jruby.RubyInteger;
import org.jruby.RubyModule;
import org.jruby.RubyObject;
import org.jruby.RubyString;
import org.jruby.anno.JRubyClass;
import org.jruby.anno.JRubyMethod;
import org.jruby.runtime.Arity;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.runtime.load.Library;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.channels.Channel;
import java.nio.channels.FileChannel;
import java.nio.file.FileSystems;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

@SuppressWarnings("ClassUnconnectedToPackage")
public class JrubyFileWatchLibrary implements Library {

    private static final BigInteger INIT32 = new BigInteger("811c9dc5", 16);
    private static final BigInteger INIT64 = new BigInteger("cbf29ce484222325", 16);
    private static final BigInteger PRIME32 = new BigInteger("01000193", 16);
    private static final BigInteger PRIME64 = new BigInteger("100000001b3", 16);
    private static final BigInteger MOD32 = new BigInteger("2").pow(32);
    private static final BigInteger MOD64 = new BigInteger("2").pow(64);

    @Override
    public void load(final Ruby runtime, final boolean wrap) {
        final RubyModule module = runtime.defineModule("FileWatch");

        RubyClass clazz = runtime.defineClassUnder("FileExt", runtime.getObject(), (runtime12, rubyClass) -> new RubyFileExt(runtime12, rubyClass), module);
        clazz.defineAnnotatedMethods(JrubyFileWatchLibrary.RubyFileExt.class);

        clazz = runtime.defineClassUnder("Fnv", runtime.getObject(), (runtime1, rubyClass) -> new JrubyFileWatchLibrary.Fnv(runtime1, rubyClass), module);
        clazz.defineAnnotatedMethods(JrubyFileWatchLibrary.Fnv.class);

    }

    @JRubyClass(name = "FileExt", parent = "Object")
    public static class RubyFileExt extends RubyObject {

        public RubyFileExt(final Ruby runtime, final RubyClass metaClass) {
            super(runtime, metaClass);
        }

        public RubyFileExt(final RubyClass metaClass) {
            super(metaClass);
        }

        @JRubyMethod(name = "open", required = 1, meta = true)
        public static RubyIO open(final ThreadContext context, final IRubyObject self, final RubyString path) throws IOException {
            final Path javapath = FileSystems.getDefault().getPath(path.asJavaString());
            final OpenOption[] options = new OpenOption[1];
            options[0] = StandardOpenOption.READ;
            final Channel channel = FileChannel.open(javapath, options);
            return new RubyIO(Ruby.getGlobalRuntime(), channel);
        }
    }

    @SuppressWarnings({"NewMethodNamingConvention", "ChainOfInstanceofChecks"})
    @JRubyClass(name = "Fnv", parent = "Object")
    public static class Fnv extends RubyObject {

        private byte[] bytes = null;
        private long size = 0L;
        private boolean open = false;

        public Fnv(final Ruby runtime, final RubyClass metaClass) {
            super(runtime, metaClass);
        }

        public Fnv(final RubyClass metaClass) {
            super(metaClass);
        }

        @JRubyMethod(name = "coerce_bignum", meta = true, required = 1)
        public static IRubyObject coerceBignum(final ThreadContext ctx, final IRubyObject recv, final IRubyObject i) {
            if (i instanceof RubyBignum) {
                return i;
            }
            if (i instanceof RubyFixnum) {
                return RubyBignum.newBignum(ctx.runtime, ((RubyFixnum)i).getBigIntegerValue());
            }
            throw ctx.runtime.newRaiseException(ctx.runtime.getClass("StandardError"), "Can't coerce");
        }

        // def initialize(data)
        @JRubyMethod(name = "initialize", required = 1)
        public IRubyObject rubyInitialize(final ThreadContext ctx, final RubyString data) {
            bytes = data.getBytes();
            size = (long) bytes.length;
            open = true;
            return ctx.nil;
        }

        @JRubyMethod(name = "close")
        public IRubyObject close(final ThreadContext ctx) {
            open = false;
            bytes = null;
            return ctx.nil;
        }

        @JRubyMethod(name = "open?")
        public IRubyObject open_p(final ThreadContext ctx) {
            if(open) {
                return ctx.runtime.getTrue();
            }
            return ctx.runtime.getFalse();
        }

        @JRubyMethod(name = "closed?")
        public IRubyObject closed_p(final ThreadContext ctx) {
            if(open) {
                return ctx.runtime.getFalse();
            }
            return ctx.runtime.getTrue();
        }

        @JRubyMethod(name = "fnv1a32", optional = 1)
        public IRubyObject fnv1a_32(final ThreadContext ctx, IRubyObject[] args) {
            IRubyObject[] args1 = args;
            if(open) {
                args1 = Arity.scanArgs(ctx.runtime, args1, 0, 1);
                return RubyBignum.newBignum(ctx.runtime, common_fnv(args1[0], INIT32, PRIME32, MOD32));
            }
            throw ctx.runtime.newRaiseException(ctx.runtime.getClass("StandardError"), "Fnv instance is closed!");
        }

        @JRubyMethod(name = "fnv1a64", optional = 1)
        public IRubyObject fnv1a_64(final ThreadContext ctx, IRubyObject[] args) {
            IRubyObject[] args1 = args;
            if(open) {
                args1 = Arity.scanArgs(ctx.runtime, args1, 0, 1);
                return RubyBignum.newBignum(ctx.runtime, common_fnv(args1[0], INIT64, PRIME64, MOD64));
            }
            throw ctx.runtime.newRaiseException(ctx.runtime.getClass("StandardError"), "Fnv instance is closed!");
        }

        private long convertLong(final IRubyObject obj) {
            if(obj instanceof RubyInteger) {
                return ((RubyInteger)obj).getLongValue();
            }
            if(obj instanceof RubyFixnum) {
                return ((RubyFixnum)obj).getLongValue();
            }

            return size;
        }

        private BigInteger common_fnv(final IRubyObject len, final BigInteger hash, final BigInteger prime, final BigInteger mod) {
            long converted = convertLong(len);

            if (converted > size) {
                converted = size;
            }

            BigInteger tempHash = hash;
            for (int idx = 0; (long) idx < converted; idx++) {
                tempHash = tempHash.xor(BigInteger.valueOf((long) ((int) bytes[idx] & 0xff)));
                tempHash = tempHash.multiply(prime).mod(mod);
            }

            return tempHash;
        }
    }

}

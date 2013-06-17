/**
 * Created with IntelliJ IDEA.
 * User: efrey
 * Date: 6/11/13
 * Time: 11:00 AM
 * To change this template use File | Settings | File Templates.
 *
 * http://bugs.sun.com/view_bug.do?bug_id=6357433
 *
 *
 */

import org.jruby.*;
import org.jruby.anno.JRubyClass;
import org.jruby.anno.JRubyMethod;
import org.jruby.util.io.ChannelDescriptor;
import org.jruby.util.io.ChannelStream;
import org.jruby.util.io.InvalidValueException;
import org.jruby.util.io.Stream;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.channels.Channel;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.nio.file.spi.FileSystemProvider;
import java.util.Iterator;

@JRubyClass(name="FileExt", parent="File", include="FileTest")
public class RubyFileExt extends RubyObject {

    public RubyFileExt(Ruby runtime, RubyClass metaClass) {
        super(runtime, metaClass);
    }

    public RubyFileExt(RubyClass metaClass) {
        super(metaClass);
    }

    @JRubyMethod
            public static RubyIO getRubyFile(String path) throws IOException, InvalidValueException{
                Path p = FileSystems.getDefault().getPath(path);
                OpenOption[] options = new OpenOption[1];
                options[0] = StandardOpenOption.READ;
                Channel channel = FileChannel.open(p, options);
                return new RubyIO(Ruby.getGlobalRuntime(), channel);
            }
}

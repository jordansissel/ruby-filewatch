
import org.logstash.filewatch.JrubyFileWatchLibrary;
import org.jruby.Ruby;
import org.jruby.runtime.load.BasicLibraryService;

import java.io.IOException;

public class JrubyFileWatchService implements BasicLibraryService {
    @Override
    public boolean basicLoad(final Ruby runtime)
            throws IOException
    {
        new JrubyFileWatchLibrary().load(runtime, false);
        return true;
    }
}

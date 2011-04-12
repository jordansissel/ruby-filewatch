import org.apache.log4j.Logger;
import org.apache.log4j.PropertyConfigurator;

public class LogTest {
  private static Logger logger = Logger.getLogger(LogTest.class);

  public static void main(String[] args) {
    //BasicConfigurator.configure();
    PropertyConfigurator.configure("log4j.properties");

    int i = 0;
    while (true) {
      logger.info("Testing: " + i);
      i++;
      try {
        Thread.sleep(100);
      }  catch (Exception e) {
      }
    }
  } /* public static void main(String[]) */
} /* public class LogTest */

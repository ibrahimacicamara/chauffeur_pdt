import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:hive/hive.dart';

class ActivitiesBox {
  static Box<CommandStatus> myCommandeStatusBox = Hive.box<CommandStatus>("commandStatus");
  static Box<GPSCoordinates> gpsCoordinatesBox = Hive.box<GPSCoordinates>("gpsCoordinates");
  static Box<MyClient> myClientBox = Hive.box<MyClient>("MyClient");
  static Box<MyOrder> orderBox = Hive.box<MyOrder>("order");
 
  static Future<void> initBox() async {
    String path = "/assets/db";
    Hive.registerAdapter(CommandStatusAdapter());
    Hive.registerAdapter(GPSCoordinatesAdapter());
    Hive.registerAdapter(MyClientAdapter());
    Hive.registerAdapter(MyOrderAdapter());
    Hive.init(path);
    await Hive.openBox<CommandStatus>("commandStatus");
    await Hive.openBox<GPSCoordinates>("gpsCoordinates");
    await Hive.openBox<MyClient>("MyClient");
    await Hive.openBox<MyOrder>("order");
  }
  // gerer les categories

  static Future<void> addtoBox(data, Box<dynamic> box) {
    return box.put(data.id, data);
  }

  static Future<void> deleteFromBox(String id, Box<dynamic> box) {
    return box.delete(id);
  }
}

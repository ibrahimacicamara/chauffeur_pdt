// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'hive_database.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class MyOrderAdapter extends TypeAdapter<MyOrder> {
  @override
  final int typeId = 0;

  @override
  MyOrder read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return MyOrder(
      userId: fields[1] as String,
      id: fields[0] as String,
      departureDate: fields[5] as DateTime,
      customerEmail: fields[2] as String,
      category: fields[3] as String,
      disposal: fields[4] as bool,
      clients: (fields[6] as List).cast<MyClient>(),
      precision: fields[15] as String,
      departureAddress: fields[7] as String,
      steps: (fields[8] as List).cast<String>(),
      personNumber: fields[9] as int,
      suitcaseNumber: fields[10] as int,
      paymentStatus: fields[11] as PaymentStatus,
      vehicule: fields[12] as String,
      commandStatus: (fields[16] as List).cast<CommandStatus>(),
      price: fields[13] as int?,
      carImages: (fields[14] as List?)?.cast<String>(),
    );
  }

  @override
  void write(BinaryWriter writer, MyOrder obj) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.userId)
      ..writeByte(2)
      ..write(obj.customerEmail)
      ..writeByte(3)
      ..write(obj.category)
      ..writeByte(4)
      ..write(obj.disposal)
      ..writeByte(5)
      ..write(obj.departureDate)
      ..writeByte(6)
      ..write(obj.clients)
      ..writeByte(7)
      ..write(obj.departureAddress)
      ..writeByte(8)
      ..write(obj.steps)
      ..writeByte(9)
      ..write(obj.personNumber)
      ..writeByte(10)
      ..write(obj.suitcaseNumber)
      ..writeByte(11)
      ..write(obj.paymentStatus)
      ..writeByte(12)
      ..write(obj.vehicule)
      ..writeByte(13)
      ..write(obj.price)
      ..writeByte(14)
      ..write(obj.carImages)
      ..writeByte(15)
      ..write(obj.precision)
      ..writeByte(16)
      ..write(obj.commandStatus);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MyOrderAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class CommandStatusAdapter extends TypeAdapter<CommandStatus> {
  @override
  final int typeId = 1;

  @override
  CommandStatus read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CommandStatus(
      date: fields[0] as DateTime,
      status: fields[1] as OrderStatus,
      id: fields[2] as String,
      location: fields[3] as GPSCoordinates,
    );
  }

  @override
  void write(BinaryWriter writer, CommandStatus obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.date)
      ..writeByte(1)
      ..write(obj.status)
      ..writeByte(2)
      ..write(obj.id)
      ..writeByte(3)
      ..write(obj.location);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class GPSCoordinatesAdapter extends TypeAdapter<GPSCoordinates> {
  @override
  final int typeId = 2;

  @override
  GPSCoordinates read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return GPSCoordinates(
      latitude: fields[0] as double,
      longitude: fields[1] as double,
    );
  }

  @override
  void write(BinaryWriter writer, GPSCoordinates obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.latitude)
      ..writeByte(1)
      ..write(obj.longitude);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GPSCoordinatesAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MyClientAdapter extends TypeAdapter<MyClient> {
  @override
  final int typeId = 3;

  @override
  MyClient read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return MyClient(
      name: fields[0] as String,
      phone: fields[1] as String,
    );
  }

  @override
  void write(BinaryWriter writer, MyClient obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.name)
      ..writeByte(1)
      ..write(obj.phone);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MyClientAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MyDriverAdapter extends TypeAdapter<MyDriver> {
  @override
  final int typeId = 4;

  @override
  MyDriver read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return MyDriver(
      name: fields[0] as String,
      phone: fields[1] as String,
      categories: (fields[2] as List).cast<String>(),
      car: fields[3] as String,
      available: fields[4] as bool,
      licensePlate: fields[5] == null ? '' : fields[5] as String,
    );
  }

  @override
  void write(BinaryWriter writer, MyDriver obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.name)
      ..writeByte(1)
      ..write(obj.phone)
      ..writeByte(2)
      ..write(obj.categories)
      ..writeByte(3)
      ..write(obj.car)
      ..writeByte(4)
      ..write(obj.available)
      ..writeByte(5)
      ..write(obj.licensePlate);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MyDriverAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

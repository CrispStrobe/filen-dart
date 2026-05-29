import 'package:filen_dart/cli.dart';

void main(List<String> arguments) async {
  final cli = FilenCLI();
  await cli.run(arguments);
}

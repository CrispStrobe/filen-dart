import 'package:filen_client/cli.dart';

void main(List<String> arguments) async {
  final cli = FilenCLI();
  await cli.run(arguments);
}

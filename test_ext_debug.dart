import 'package:path/path.dart' as p;

void main() {
  const f = 'IMG_0002.mp~2';
  print("extension('$f'): [${p.extension(f)}]");
  print("withoutExtension('$f'): [${p.withoutExtension(f)}]");
  print("basenameWithoutExtension: [${p.basenameWithoutExtension(f)}]");
  print("lastIndexOf('.'): ${f.lastIndexOf('.')}");
  print("substring(0, lastDot): [${f.substring(0, f.lastIndexOf('.'))}]");

  // Also test with a full path
  const full = '/takeout/Google Photos/Photos from 2023/IMG_0002.mp~2';
  print("---");
  print("extension(full): [${p.extension(full)}]");
  print("withoutExtension(full): [${p.withoutExtension(full)}]");
}

using MoDi.Protocol;
using System.Text.RegularExpressions;

var codec = new PacketHeaderCodec();
var packet = new Packet { Type = PacketType.Audio, LinkType = 1, Sequence = 0x12345678, Payload = [0x11,0x22,0x33] };
var wire = codec.Encode(packet);
Console.WriteLine(Convert.ToHexString(wire));
void Probe(string name, byte[] bytes, bool expected) {
    var accepted = codec.Decode(bytes).HasValue;
    if (accepted != expected) throw new Exception($"Unexpected original decoder behavior: {name}");
}
Probe("valid",wire,true);
Probe("trailing",[..wire,0xff],false);
for (int length=0;length<wire.Length;length++) Probe("truncated",wire[..length],false);
for(int i=0;i<15;i++) {
    var changed=(byte[])wire.Clone(); changed[i]=0xff; Probe($"offset {i} = FF",changed,i is >=6 and <=10);
}
var empty = codec.Encode(new Packet { Type=PacketType.Hello, LinkType=1, Sequence=0, Payload=[] });
Probe("empty",empty,true);
for (int type=0;type<256;type++) {
    var changed=(byte[])wire.Clone(); changed[5]=(byte)type;
    Probe($"type {type}",changed,type is >=1 and <=7);
}
Console.WriteLine("PASS: original decoder framing and all 256 message-type values");

// Validate the exact expected bytes committed in the Swift unit tests.
var testPath = Path.Combine(AppContext.BaseDirectory, "../../../../../MoDiConnectTests/ProtocolCompatibilityTests.swift");
var matches = Regex.Matches(File.ReadAllText(testPath), @"\(\.(hello|helloAck|audio), (0|0x12345678|UInt32.max), ""([0-9A-F]*)"", ""([0-9A-F]*)""\)");
if (matches.Count != 4) throw new Exception("Missing Swift fixtures");
foreach (Match fixture in matches) {
    var type = fixture.Groups[1].Value switch { "hello" => PacketType.Hello, "helloAck" => PacketType.HelloAck, _ => PacketType.Audio };
    var seq = fixture.Groups[2].Value switch { "0" => 0u, "UInt32.max" => uint.MaxValue, _ => 0x12345678u };
    var expected = Convert.FromHexString(fixture.Groups[4].Value);
    var original = new Packet { Type=type, LinkType=1, Sequence=seq, Payload=Convert.FromHexString(fixture.Groups[3].Value) };
    if (!codec.Encode(original).SequenceEqual(expected)) throw new Exception("Swift fixture differs from official encoder");
    if (!codec.Decode(expected).HasValue) throw new Exception("Official decoder rejected fixture");
}
Console.WriteLine("PASS: 4 Swift wire fixtures match bundled .NET encoder and decoder");

if (args.Length == 1) {
    int count = 0;
    foreach (var line in File.ReadLines(args[0])) {
        var swiftWire = Convert.FromHexString(line);
        var decoded = codec.Decode(swiftWire) ?? throw new Exception("Official decoder rejected Swift output");
        if (!codec.Encode(decoded).SequenceEqual(swiftWire)) throw new Exception("Official re-encode differs from Swift output");
        count++;
    }
    if (count != 224) throw new Exception($"Expected 224 Swift packets, got {count}");
    Console.WriteLine($"PASS: {count} production Swift packets decoded and re-encoded byte-for-byte by bundled .NET codec");
}

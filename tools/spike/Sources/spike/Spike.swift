import Foundation

let usage = """
usage: spike <command> <file> [options]   (every command takes --runs N, default 3)

  decode   <file> [--max 240] [--format bgra|420f] [--scale reader|vimage|coreimage]
                  [--metric] [--seconds S]
  faces    <file> [--max 720] [--api swift|vn] [--device default|cpu|gpu|ane]
                  [--revision 3|4] [--every 10] [--frames 200] [--start S]
  devices         (face-rectangle revisions and compute devices)
  combined <file> [--every 10] [--layout single|dual] [--scan 240] [--face 720]
                  [--api swift|vn] [--device default|cpu|gpu|ane] [--seconds S]
  random   <file> [--count 16] [--tolerance 0.5] [--max 720]
  ffmpeg   <file> [--max 240] [--hwaccel] [--seconds S]
"""

@main
struct Spike {
    static func main() async {
        let args = Args(CommandLine.arguments)
        do {
            switch args.command {
            case "decode": try await runDecode(args)
            case "faces": try await runFaces(args)
            case "devices": printFaceDevices()
            case "combined": try await runCombined(args)
            case "random": try await runRandom(args)
            case "ffmpeg": try await runFFmpeg(args)
            default: log(usage)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}

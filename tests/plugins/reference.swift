import Foundation

struct ReplayFrame: Decodable { let now:Double;let deltaTime:Double;let audio:FeatureInput;let keyboard:KeyboardInput }
struct ReferenceFrame: Encodable { let head:Double;let y:Double;let scale:Double;let opacity:Double;let sway:Double;let traceCount:Int;let rings:[Ring];let tail:Int;let flight:[String:Double];let trace:[Trace];let continuous:Bool }
struct Trace:Encodable {let x:Double;let y:Double;let segment:Int;let progress:Double?}
struct Ring:Encodable { let x:Double;let y:Double;let radius:Double;let opacity:Double;let rotation:Double }
@main struct PluginReference {
    @MainActor static func main() throws {
        let frames=try JSONDecoder().decode([ReplayFrame].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var head=PixelHeadScene();var tail=PixelTailScene();let staff=StaffNoteSimulation(beatSeed:1)
        let flight=PencilFlightSimulation(world:SoundFlightWorld(seed:1));flight.activate(viewport:.desktop)
        staff.activate(viewport:VisualizationViewport(width:800,height:160,scale:1))
        var results=[ReferenceFrame]()
        for frame in frames {
            head.advance(seconds:frame.deltaTime,input:frame.keyboard);tail.advance(frame.audio,seconds:frame.deltaTime);flight.update(input:frame.audio,deltaTime:frame.deltaTime)
            staff.receive(keyboard:frame.keyboard);staff.update(input:frame.audio,deltaTime:frame.deltaTime)
            results.append(ReferenceFrame(head:head.angle,y:staff.scene.noteY,scale:staff.scene.scale,opacity:staff.scene.opacity,sway:staff.scene.swayAngle,traceCount:staff.scene.trace.count,rings:staff.beatRings.rings.map { Ring(x:$0.x,y:$0.y,radius:$0.radius,opacity:$0.opacity,rotation:$0.rotation) },tail:tail.spriteIndex,flight:["y":flight.world.birdY,"rotation":flight.world.birdAngle,"scaleX":flight.world.birdScale/flight.world.birdStretch,"scaleY":flight.world.birdScale*flight.world.birdStretch,"score":Double(flight.world.score)],trace:staff.scene.trace.map {Trace(x:staff.scene.traceX($0),y:$0.y,segment:$0.segment,progress:$0.join?.progress(at:staff.scene.elapsed))},continuous:staff.scene.hasContinuousTraceTail))
        }
        try JSONEncoder().encode(results).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
    }
}

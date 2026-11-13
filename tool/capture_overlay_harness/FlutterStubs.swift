// Minimal stand-ins for the Flutter symbols CapturePlugin.swift references, so
// the real file can be compiled and driven outside the app.
import CoreVideo
import Foundation

public typealias FlutterResult = (Any?) -> Void
public let FlutterMethodNotImplemented = NSObject()

public class FlutterError: NSObject {
  public init(code: String, message: String?, details: Any?) {}
}
public class FlutterBinaryMessenger: NSObject {}
public class FlutterMethodCall: NSObject {
  public let method: String
  public let arguments: Any?
  public init(methodName: String, arguments: Any?) { self.method = methodName; self.arguments = arguments }
}
// Gene - Nov, 13, 2026: Add FlutterMethodChannel.invokeMethod, FlutterStandardTypedData, FlutterTexture, and FlutterTextureRegistry stubs for standalone overlay harness compilation.
// Old implementation:
// public class FlutterMethodChannel: NSObject {
//   public init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
//   public func setMethodCallHandler(_ h: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?) {}
// }
// public class FlutterPluginRegistrar: NSObject {
//   public var messenger: FlutterBinaryMessenger { FlutterBinaryMessenger() }
// }
public class FlutterStandardTypedData: NSObject {
  public let data: Data
  public init(bytes: Data) {
    self.data = bytes
    super.init()
  }
}

public protocol FlutterTexture: NSObjectProtocol {
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
}

public protocol FlutterTextureRegistry: AnyObject {
  func register(_ texture: FlutterTexture) -> Int64
  func textureFrameAvailable(_ textureId: Int64)
  func unregisterTexture(_ textureId: Int64)
}

private final class StubTextureRegistry: FlutterTextureRegistry {
  func register(_ texture: FlutterTexture) -> Int64 { 1 }
  func textureFrameAvailable(_ textureId: Int64) {}
  func unregisterTexture(_ textureId: Int64) {}
}

public class FlutterMethodChannel: NSObject {
  public init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
  public func setMethodCallHandler(_ h: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?) {}
  public func invokeMethod(_ method: String, arguments: Any?) {}
}

public class FlutterPluginRegistrar: NSObject {
  public var messenger: FlutterBinaryMessenger { FlutterBinaryMessenger() }
  public var textures: FlutterTextureRegistry { StubTextureRegistry() }
}

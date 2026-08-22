// Minimal stand-ins for the Flutter symbols CapturePlugin.swift references, so
// the real file can be compiled and driven outside the app.
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
public class FlutterMethodChannel: NSObject {
  public init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
  public func setMethodCallHandler(_ h: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?) {}
}
public class FlutterPluginRegistrar: NSObject {
  public var messenger: FlutterBinaryMessenger { FlutterBinaryMessenger() }
}

//
//  JavaEncoder.swift
//  jniBridge
//
//  Created by Andrew on 10/14/17.
//

import Foundation
import CoreFoundation
import java_swift
import AnyCodable

public enum MissingFieldsStrategy: Error {
    case `throw`
    case ignore
}

public enum JavaCodingError: Error {
    case notSupported(String)
    case cantCreateObject(String)
    case cantFindObject(String)
    case nilNotSupported(String)
    case wrongArrayLength
}

indirect enum JNIStorageType {
    case object(className: String)
    case array
    case dictionary
    case anyCodable(codable: JNIStorageType)
    
    var sig: String {
        switch self {
        case .object(let className):
            return "L\(className);"
        case .array:
            return "L\(ArrayListClassname);"
        case .dictionary:
            return "L\(HashMapClassname);"
        case .anyCodable(let codable):
            return codable.sig
        }
    }
}

class JNIStorageObject {
    let type: JNIStorageType
    var javaObject: jobject!
    
    init(type: JNIStorageType, javaObject: jobject) {
        self.type = type
        self.javaObject = javaObject
    }
    
    init(type: JNIStorageType) {
        self.type = type
    }
    
    deinit {
        JNI.api.DeleteLocalRef(JNI.env, javaObject)
    }
}

/// `JavaEncoder` facilitates the encoding of `Encodable` values into JSON.
open class JavaEncoder: Encoder {

    // MARK: Properties
    
    /// The path to the current point in encoding.
    public var codingPath: [CodingKey]
    
    /// Contextual user-provided information for use during encoding.
    public var userInfo: [CodingUserInfoKey : Any] {
        return [:]
    }
    
    fileprivate let package: String
    fileprivate var javaObjects: [JNIStorageObject]
    fileprivate let missingFieldsStrategy: MissingFieldsStrategy
    
    // MARK: - Constructing a JSON Encoder
    /// Initializes `self` with default strategies.
    public init(forPackage: String, missingFieldsStrategy: MissingFieldsStrategy = .throw) {
        self.codingPath = [CodingKey]()
        self.package = forPackage
        self.javaObjects = [JNIStorageObject]()
        self.missingFieldsStrategy = missingFieldsStrategy
    }
    
    // MARK: - Encoding Values
    /// Encodes the given top-level value and returns its JSON representation.
    ///
    /// - parameter value: The value to encode.
    /// - returns: A new `Data` value containing the encoded JSON data.
    /// - throws: `EncodingError.invalidValue` if a non-conforming floating-point value is encountered during encoding, and the encoding strategy is `.throw`.
    /// - throws: An error if any value throws an error during encoding.
    open func encode<T : Encodable>(_ value: T) throws -> jobject {
        do {
            let storage = try self.box(value)
            assert(self.javaObjects.count == 0, "Missing encoding for \(self.javaObjects.count) objects")
            return JNI.api.NewLocalRef(JNI.env, storage.javaObject)!
        }
        catch {
            // clean all reference if failed
            self.javaObjects.removeAll()
            throw error
        }

    }
    
    // MARK: - Encoder Methods
    public func container<Key>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        guard let storage = self.javaObjects.popLast() else {
            preconditionFailure("No instances in stack")
        }
        switch storage.type {
        case .dictionary:
            let container = JavaHashMapKeyedContainer<Key>(referencing: self, codingPath: self.codingPath, jniStorage: storage)
            return KeyedEncodingContainer(container)
        case let .object(className):
            let container = JavaObjectContainer<Key>(referencing: self, codingPath: self.codingPath, javaClass: className, jniStorage: storage)
            return KeyedEncodingContainer(container)
        case .anyCodable:
            let container = JavaAnyCodableContainer<Key>(referencing: self, codingPath: self.codingPath, jniStorage: storage)
            return KeyedEncodingContainer(container)
        default:
            fatalError("Only keyed containers")
        }
    }
    
    public func unkeyedContainer() -> UnkeyedEncodingContainer {
        guard let storage = self.javaObjects.popLast() else {
            preconditionFailure("No instances in stack")
        }
        switch storage.type {
        case .dictionary:
            return JavaHashMapUnkeyedContainer(referencing: self, codingPath: self.codingPath, jniStorage: storage)
        case .array:
            return JavaArrayContainer(referencing: self, codingPath: self.codingPath, jniStorage: storage)
        default:
            fatalError("Only unkeyed containers")
        }
    }
    
    public func singleValueContainer() -> SingleValueEncodingContainer {
        guard let storage = self.javaObjects.popLast() else {
            preconditionFailure("No instances in stack")
        }
        switch storage.type {
        case let .object(className):
            return JavaEnumValueEncodingContainer(encoder: self, javaClass: className, jniStorage: storage)
        default:
            fatalError("Only object type supported here")
        }
        
    }
}

// MARK: - Encoding Containers
fileprivate class JavaObjectContainer<K : CodingKey> : KeyedEncodingContainerProtocol {
    
    typealias Key = K
    
    // MARK: Properties
    /// A reference to the encoder we're writing to.
    private let encoder: JavaEncoder
    
    private let javaClass: String
    private let jniStorage: JNIStorageObject
    
    /// The path of coding keys taken to get to this point in encoding.
    private(set) public var codingPath: [CodingKey]
    
    // MARK: - Initialization
    /// Initializes `self` with the given references.
    fileprivate init(referencing encoder: JavaEncoder, codingPath: [CodingKey], javaClass: String, jniStorage: JNIStorageObject) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.javaClass = javaClass
        self.jniStorage = jniStorage
    }
    
    private var javaObject: jobject {
        return jniStorage.javaObject
    }
    
    // MARK: - KeyedEncodingContainerProtocol Methods
    public func encodeNil(forKey key: Key) throws {
        throw JavaCodingError.notSupported("JavaObjectContainer.encodeNil(forKey: \(key)")
    }
    
    public func encode<T : Encodable>(_ value: T, forKey key: Key) throws {
        do {
            let object = try self.encoder.box(value)
            let filed = try JNI.getJavaField(forClass: self.javaClass, field: key.stringValue, sig: object.type.sig)
            JNI.api.SetObjectField(JNI.env, self.javaObject, filed, object.javaObject)
        }
        catch {
            if self.encoder.missingFieldsStrategy == .ignore {
                NSLog("Ignore error: \(error)")
            }
            else {
                throw error
            }
        }
    }
    
    public func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        preconditionFailure("Not implemented: nestedContainer")
    }
    
    public func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        preconditionFailure("Not implemented: nestedUnkeyedContainer")
    }
    
    public func superEncoder() -> Encoder {
        self.encoder.javaObjects.append(self.jniStorage)
        return self.encoder
    }
    
    public func superEncoder(forKey key: Key) -> Encoder {
        preconditionFailure("Not implemented: superEncoder")
    }
}

// MARK: - Encoding Containers
// Keyed HashMap Container used for [String: Any] or [Int: Any]
fileprivate class JavaHashMapKeyedContainer<K : CodingKey> : KeyedEncodingContainerProtocol {
    
    typealias Key = K
    
    // MARK: Properties
    /// A reference to the encoder we're writing to.
    private let encoder: JavaEncoder
    
    private let jniStorage: JNIStorageObject
    
    /// The path of coding keys taken to get to this point in encoding.
    private(set) public var codingPath: [CodingKey]
    
    // MARK: - Initialization
    /// Initializes `self` with the given references.
    fileprivate init(referencing encoder: JavaEncoder, codingPath: [CodingKey], jniStorage: JNIStorageObject) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.jniStorage = jniStorage
    }
    
    private var javaObject: jobject {
        return jniStorage.javaObject
    }
    
    // MARK: - KeyedEncodingContainerProtocol Methods
    public func encodeNil(forKey key: Key) throws {
        throw JavaCodingError.notSupported("JavaHashMapContainer.encodeNil(forKey: \(key))")
    }
    
    public func encode<T : Encodable>(_ value: T, forKey key: Key) throws {
        let keyStorage: JNIStorageObject
        if let intValue = key.intValue {
            keyStorage = try self.encoder.box(intValue)
        }
        else {
            keyStorage = try self.encoder.box(key.stringValue)
        }
        
        let valueStorage = try self.encoder.box(value)
        let result = JNI.CallObjectMethod(javaObject, methodID: HashMapPutMethod, args: [jvalue(l: keyStorage.javaObject), jvalue(l: valueStorage.javaObject)])
        assert(result == nil, "Rewrite for key \(key.stringValue)")
    }
    
    public func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        preconditionFailure("Not implemented: nestedContainer")
    }
    
    public func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        preconditionFailure("Not implemented: nestedUnkeyedContainer")
    }
    
    public func superEncoder() -> Encoder {
        preconditionFailure("Not implemented: superEncoder")
    }
    
    public func superEncoder(forKey key: Key) -> Encoder {
        preconditionFailure("Not implemented: superEncoder")
    }
}

fileprivate class JavaHashMapUnkeyedContainer : UnkeyedEncodingContainer {
    // MARK: Properties
    /// A reference to the encoder we're writing to.
    private let encoder: JavaEncoder
    
    /// The path of coding keys taken to get to this point in encoding.
    private(set) public var codingPath: [CodingKey]
    
    /// The number of elements encoded into the container.
    public private(set) var count: Int = 0
    
    private let jniStorage: JNIStorageObject
    
    private var javaKey: JNIStorageObject?
    
    // MARK: - Initialization
    /// Initializes `self` with the given references.
    fileprivate init(referencing encoder: JavaEncoder, codingPath: [CodingKey], jniStorage: JNIStorageObject) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.jniStorage = jniStorage
    }
    
    private var javaObject: jobject {
        return jniStorage.javaObject
    }
    
    // MARK: - UnkeyedEncodingContainer Methods
    public func encodeNil() throws {
        throw JavaCodingError.notSupported("JavaArrayContainer.encodeNil")
    }
    
    public func encode<T : Encodable>(_ value: T) throws {
        let javaValue = try self.encoder.box(value)
        if let javaKey = self.javaKey {
            let result = JNI.CallObjectMethod(javaObject, methodID: HashMapPutMethod, args: [jvalue(l: javaKey.javaObject), jvalue(l: javaValue.javaObject)])
            assert(result == nil, "Rewrite for key")
            self.javaKey = nil
        }
        else {
            self.javaKey = javaValue
        }
        count += 1
    }
    
    public func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        preconditionFailure("Not implemented: nestedContainer")
    }
    
    public func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        preconditionFailure("Not implemented: nestedUnkeyedContainer")
    }
    
    public func superEncoder() -> Encoder {
        preconditionFailure("Not implemented: superEncoder")
    }
}

fileprivate class JavaArrayContainer : UnkeyedEncodingContainer {
    // MARK: Properties
    /// A reference to the encoder we're writing to.
    private let encoder: JavaEncoder
    
    /// The path of coding keys taken to get to this point in encoding.
    private(set) public var codingPath: [CodingKey]
    
    /// The number of elements encoded into the container.
    public private(set) var count: Int = 0
    
    private let jniStorage: JNIStorageObject
    
    // MARK: - Initialization
    /// Initializes `self` with the given references.
    fileprivate init(referencing encoder: JavaEncoder, codingPath: [CodingKey], jniStorage: JNIStorageObject) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.jniStorage = jniStorage
    }
    
    private var javaObject: jobject {
        return jniStorage.javaObject
    }
    
    // MARK: - UnkeyedEncodingContainer Methods
    public func encodeNil() throws {
        throw JavaCodingError.notSupported("JavaArrayContainer.encodeNil")
    }
    
    public func encode<T : Encodable>(_ value: T) throws {
        let storeObject = try self.encoder.box(value)
        let rewrite = JNI.CallBooleanMethod(self.javaObject, methodID: ArrayListAddMethod, args: [jvalue(l: storeObject.javaObject)])
        assert(rewrite == JNI.TRUE, "ArrayList should always return true from add()")
        count += 1
    }
    
    public func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        preconditionFailure("Not implemented: nestedContainer")
    }
    
    public func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        preconditionFailure("Not implemented: nestedUnkeyedContainer")
    }
    
    public func superEncoder() -> Encoder {
        preconditionFailure("Not implemented: superEncoder")
    }
}

class JavaEnumValueEncodingContainer: SingleValueEncodingContainer {
    
    var codingPath: [CodingKey]
    let encoder: JavaEncoder
    
    private var javaClass: String
    private var jniStorage: JNIStorageObject
    
    init(encoder: JavaEncoder, javaClass: String, jniStorage: JNIStorageObject) {
        self.codingPath = [CodingKey]()
        self.encoder = encoder
        self.javaClass = javaClass
        self.jniStorage = jniStorage
    }
    
    public func encodeNil() throws {
        throw JavaCodingError.notSupported("JavaSingleValueEncodingContainer.encodeNil")
    }
    
    public func encode<T : Encodable>(_ value: T) throws {
        let rawValue = try self.encoder.box(value)
        let clazz = try JNI.getJavaClass(javaClass)
        // If jniStorage.javaObject == nil its enum, else optionSet
        if jniStorage.javaObject == nil {
            let valueOfMethodID = try JNI.getStaticJavaMethod(forClass: javaClass, method: "valueOf", sig: "(\(rawValue.type.sig))L\(javaClass);")
            guard let javaObject = JNI.CallStaticObjectMethod(clazz, methodID: valueOfMethodID, args: [jvalue(l: rawValue.javaObject)]) else {
                throw JavaCodingError.nilNotSupported("\(javaClass).valueOf()")
            }
            jniStorage.javaObject = javaObject
        }
        else {
            let filed = try JNI.getJavaField(forClass: self.javaClass, field: "rawValue", sig: rawValue.type.sig)
            JNI.api.SetObjectField(JNI.env, self.jniStorage.javaObject, filed, rawValue.javaObject)
        }
    }
}

// MARK: - AnyCodable Containers
fileprivate class JavaAnyCodableContainer<K : CodingKey> : KeyedEncodingContainerProtocol {

    typealias Key = K

    // MARK: Properties
    /// A reference to the encoder we're writing to.
    private let encoder: JavaEncoder
    private let jniStorage: JNIStorageObject

    /// The path of coding keys taken to get to this point in encoding.
    private(set) public var codingPath: [CodingKey]

    // MARK: - Initialization
    /// Initializes `self` with the given references.
    fileprivate init(referencing encoder: JavaEncoder, codingPath: [CodingKey], jniStorage: JNIStorageObject) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.jniStorage = jniStorage
    }

    private var javaObject: jobject {
        return jniStorage.javaObject
    }

    // MARK: - KeyedEncodingContainerProtocol Methods
    public func encodeNil(forKey key: Key) throws {
        throw JavaCodingError.notSupported("JavaObjectContainer.encodeNil(forKey: \(key)")
    }

    public func encode<T : Encodable>(_ value: T, forKey key: Key) throws {
        if key.stringValue == "typeName" {
            // ignore typeName
            return
        }
        do {
            let jniObject = try self.encoder.box(value)
            self.jniStorage.javaObject = JNI.api.NewLocalRef(JNI.env, jniObject.javaObject)
        }
        catch {
            if self.encoder.missingFieldsStrategy == .ignore {
                NSLog("Ignore error: \(error)")
            }
            else {
                throw error
            }
        }
    }

    public func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        preconditionFailure("Not implemented: nestedContainer")
    }

    public func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        switch self.jniStorage.type {
        case let .anyCodable(codable):
            switch codable {
            case .dictionary:
                return JavaHashMapUnkeyedContainer(referencing: self.encoder, codingPath: self.codingPath, jniStorage: self.jniStorage)
            case .array:
                return JavaArrayContainer(referencing: self.encoder, codingPath: self.codingPath, jniStorage: self.jniStorage)
            default:
                fatalError("Only single containers")
            }
        default:
            fatalError("Only single containers")
        }
    }

    public func superEncoder() -> Encoder {
        preconditionFailure("Not implemented: superEncoder")
    }

    public func superEncoder(forKey key: Key) -> Encoder {
        preconditionFailure("Not implemented: superEncoder")
    }
}

extension JavaEncoder {
    
    fileprivate func box<T: Encodable>(_ value: T) throws -> JNIStorageObject {
        let storage: JNIStorageObject
        
        if T.self == Int.self {
            let valueInt = value as! Int
            // jint for macOS and Android defferent, that's why we make cast to jint() here
            let args = [jvalue(i: jint(valueInt))]
            let javaObject = JNI.NewObject(IntegerClass, methodID: IntegerConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: IntegerClassname), javaObject: javaObject!)
        }
        else if T.self == Int8.self {
            let valueInt8 = value as! Int8
            let args = [jvalue(b: valueInt8)]
            let javaObject = JNI.NewObject(ByteClass, methodID: ByteConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: ByteClassname), javaObject: javaObject!)
        }
        else if T.self == Int16.self {
            let valueInt16 = value as! Int16
            let args = [jvalue(s: valueInt16)]
            let javaObject = JNI.NewObject(ShortClass, methodID: ShortConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: ShortClassname), javaObject: javaObject!)
        }
        else if T.self == Int32.self {
            let valueInt32 = value as! Int32
            let args = [jvalue(i: jint(valueInt32))]
            let javaObject = JNI.NewObject(IntegerClass, methodID: IntegerConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: IntegerClassname), javaObject: javaObject!)
        }
        else if T.self == Int64.self {
            let valueInt64 = value as! Int64
            let args = [jvalue(j: valueInt64)]
            let javaObject = JNI.NewObject(LongClass, methodID: LongConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: LongClassname), javaObject: javaObject!)
        }
        else if T.self == UInt.self {
            let valueUInt = value as! UInt
            let args = [jvalue(j:  Int64(valueUInt))]
            let javaObject = JNI.NewObject(LongClass, methodID: LongConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: LongClassname), javaObject: javaObject!)
        }
        else if T.self == UInt8.self {
            let valueUInt8 = value as! UInt8
            let args = [jvalue(s: Int16(valueUInt8))]
            let javaObject = JNI.NewObject(ShortClass, methodID: ShortConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: ShortClassname), javaObject: javaObject!)
        }
        else if T.self == UInt16.self {
            let valueUInt16 = value as! UInt16
            let args = [jvalue(i: jint(valueUInt16))]
            let javaObject = JNI.NewObject(IntegerClass, methodID: IntegerConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: IntegerClassname), javaObject: javaObject!)
        }
        else if T.self == UInt32.self {
            let valueUInt32 = value as! UInt32
            let args = [jvalue(j: Int64(valueUInt32))]
            let javaObject = JNI.NewObject(LongClass, methodID: LongConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: LongClassname), javaObject: javaObject!)
        }
        else if T.self == UInt64.self {
            let valueInt64 = value as! UInt64
            var locals = [jobject]()
            let args = [jvalue(l: String(valueInt64).localJavaObject(&locals))]
            let javaObject = JNI.check(JNI.NewObject(BigIntegerClass, methodID: BigIntegerConstructor, args: args), &locals)
            storage = JNIStorageObject.init(type: .object(className: BigIntegerClassname), javaObject: javaObject!)
        }
        else if T.self == Bool.self {
            let valueBool = value as! Bool
            let args = [jvalue(z: valueBool ? JNI.TRUE : JNI.FALSE)]
            let javaObject = JNI.NewObject(BooleanClass, methodID: BooleanConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: BooleanClassname), javaObject: javaObject!)
        }
        else if T.self == String.self {
            let valueString = value as! String
            var locals = [jobject]()
            let javaObject = valueString.localJavaObject(&locals)
            // Locals ignored because JNIStorageObject take ownership of LocalReference
            storage = JNIStorageObject.init(type: .object(className: StringClassname), javaObject: javaObject!)
        }
        else if T.self == Date.self {
            let valueDate = value as! Date
            let args = [jvalue(j: jlong(valueDate.timeIntervalSince1970 * 1000))]
            let dateObject = JNI.NewObject(DateClass, methodID: DateConstructor, args: args)
            storage = JNIStorageObject.init(type: .object(className: DateClassname), javaObject: dateObject!)
        }
        else if T.self == URL.self {
            var locals = [jobject]()
            let javaString = (value as! URL).absoluteString.localJavaObject(&locals)
            let args = [jvalue(l: javaString)]
            let uriObject = JNI.check(JNI.CallStaticObjectMethod(UriClass, methodID: UriConstructor!, args: args), &locals)
            storage = JNIStorageObject.init(type: .object(className: UriClassname), javaObject: uriObject!)
        }
        else if T.self == AnyCodable.self {
            let anyCodableValue = value as! AnyCodable
            let storageType: JNIStorageType
            let fullClassName: String
            if anyCodableValue.typeName == AnyCodable.DictionaryTypeName {
                fullClassName = HashMapClassname
                storageType = .anyCodable(codable: .dictionary)
            }
            else if anyCodableValue.typeName == AnyCodable.ArrayTypeName {
                fullClassName = ArrayListClassname
                storageType = .anyCodable(codable: .array)
            }
            else {
                fullClassName = package  + "/" + anyCodableValue.typeName
                storageType = .anyCodable(codable: .object(className: fullClassName))
            }
            let javaClass = try JNI.getJavaClass(fullClassName)
            let emptyConstructor = try JNI.getJavaEmptyConstructor(forClass: fullClassName)
            guard let javaObject = JNI.api.NewObjectA(JNI.env, javaClass, emptyConstructor, nil) else {
                throw JavaCodingError.cantCreateObject(fullClassName)
            }
            storage = JNIStorageObject(type: storageType, javaObject: javaObject)
            javaObjects.append(storage)
            try anyCodableValue.encode(to: self)
        }
        else if Mirror(reflecting: value).displayStyle == .enum {
            let fullClassName = package  + "/" + String(describing: type(of: value))
            // We don't create object for enum. Should be created at JavaEnumValueEncodingContainer
            storage = JNIStorageObject(type: .object(className: fullClassName))
            javaObjects.append(storage)
            try value.encode(to: self)
        }
        else {
            let storageType: JNIStorageType
            let fullClassName: String
            if value is [AnyHashable: Encodable] {
                fullClassName = HashMapClassname
                storageType = .dictionary
            }
            else if value is [Encodable] {
                fullClassName = ArrayListClassname
                storageType = .array
            }
            else {
                fullClassName = package  + "/" + String(describing: type(of: value))
                storageType = .object(className: fullClassName)
            }
            let javaClass = try JNI.getJavaClass(fullClassName)
            let emptyConstructor = try JNI.getJavaEmptyConstructor(forClass: fullClassName)
            guard let javaObject = JNI.api.NewObjectA(JNI.env, javaClass, emptyConstructor, nil) else {
                throw JavaCodingError.cantCreateObject(fullClassName)
            }
            storage = JNIStorageObject(type: storageType, javaObject: javaObject)
            javaObjects.append(storage)
            try value.encode(to: self)
        }
        return storage
    }
}

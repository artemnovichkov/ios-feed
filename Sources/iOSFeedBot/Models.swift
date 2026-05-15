import Foundation

struct Blog: Codable, Sendable {
    let title: String
    let siteUrl: String
    let feedUrl: String?

    enum CodingKeys: String, CodingKey {
        case title
        case siteUrl = "site_url"
        case feedUrl = "feed_url"
    }
}

struct Article: Sendable {
    let title: String
    let url: String
    let description: String?
    let pubDate: Date
}

struct OpenAIRequest: Codable, Sendable {
    var model: String = Config.openaiModel
    let messages: [Message]
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
    }

    init(
        model: String = Config.openaiModel,
        messages: [Message],
        responseFormat: ResponseFormat? = nil
    ) {
        self.model = model
        self.messages = messages
        self.responseFormat = responseFormat
    }
    
    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }
}

struct ResponseFormat: Codable, Sendable {
    let type: String
    let jsonSchema: JSONSchema

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    init(name: String, schema: JSONValue) {
        self.type = "json_schema"
        self.jsonSchema = JSONSchema(name: name, strict: true, schema: schema)
    }

    struct JSONSchema: Codable, Sendable {
        let name: String
        let strict: Bool
        let schema: JSONValue
    }
}

enum JSONValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }
}

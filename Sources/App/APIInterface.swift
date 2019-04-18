//
//  APIInterface.swift
//  App
//
//  Created by Clément NONN on 10/03/2019.
//

import Vapor

final class APIInterface {
    let client: Client
    let logger: Logger
    let baseUrl: URL

    private func url(_ paths: String...) -> URL {
        var url = baseUrl
        for path in paths {
            url.appendPathComponent(path)
        }
        return url
    }

    init(client: Client, logger: Logger, baseUrl: URL) {
        self.client = client
        self.logger = logger
        self.baseUrl = baseUrl
    }

    func talks() -> Future<[PublicTalk]> {
        let url = self.url("talk", "all")
        return client.get(url).flatMap { try $0.content.decode([PublicTalk].self) }
    }

    func myTalks(user: User) -> Future<[PublicTalk]> {
        let url = self.url("talk")
        return client.get(url, headers: ["Authorization": user.bearerAuth]).flatMap { try $0.content.decode([PublicTalk].self) }
    }

    func usernames() -> Future<[String]> {
        let url = self.url("users")
        return client.get(url)
            .flatMap { try $0.content.decode([PublicUser].self) }
            .map { $0.map { $0.username } }
    }

    func connexion(userRequest: PublicUserRequest) -> Future<User> {
        let meUrl = self.url("user", "connect")
        let client = self.client
        let strongSelf = self
        return client.get(meUrl, headers: ["Authorization": userRequest.basicAuth]).flatMap { [weak self] response in
            switch response.http.status {
            case .ok:
                return try response.content.decode(User.self)
            case .unauthorized:
                throw VaporError(identifier: "Wrong Connexion", reason: "The username / password couple is not good")
            case .internalServerError:
                throw VaporError(identifier: "Wrong Connexion", reason: "Sorry, the API couldn't respond. Try again...")
            case .preconditionFailed:
                return strongSelf.signin(userRequest: userRequest).flatMap {
                    client.get(meUrl, headers: ["Authorization": userRequest.basicAuth])
                }.flatMap {
                    return try $0.content.decode(User.self)
                }
            default:
                self?.logger.error("this is an error to catch : \(response.debugDescription)")
                throw VaporError(identifier: "Wrong Connexion", reason: "Unknown response : \(response.debugDescription)")
            }
        }
    }

    func signin(userRequest: PublicUserRequest) -> Future<Void> {
        let userUrl = self.url("user")
        return client.post(userUrl, headers: ["Content-Type": "application/json"], beforeSend: { request in
            try request.content.encode(userRequest)
        }).map { [weak self] response in
            guard response.http.status != .badRequest else {
                self?.logger.warning("User not created : \(response.debugDescription)")
                throw VaporError(identifier: "couldn't create user", reason: "this user may already exist")
            }

            guard response.http.status == .ok else {
                self?.logger.warning("User not created : \(response.debugDescription)")
                throw VaporError(identifier: "couldn't create user", reason: "return status not ok for sign in")
            }

            return ()
        }
    }

    func createTalk(talkRequest: PublicTalkRequest, user: User) -> Future<Void> {
        let url = self.url("talk")
        return client.post(
            url,
            headers: [
                "Content-Type": "application/json",
                "Authorization": user.bearerAuth
            ],
            beforeSend: { request in
                try request.content.encode(talkRequest)
            }
        ).map {
            guard [.ok, .created].contains($0.http.status) else { throw VaporError(identifier: "bad creation", reason: "return status not ok for creating a talk") }

            return ()
        }
    }
}

extension APIInterface: ServiceType {
    enum Error: String, Debuggable {
        case apiVariablesNeeded
        case noUrl

        var identifier: String {
            return "apiInterface.\(self.rawValue)"
        }

        var reason: String {
            switch self {
            case .apiVariablesNeeded:
                return "the environment variables for api hostname and port isn't set. please provide these informations"
            case .noUrl:
                return "couldn't create url with hostname and port provided"
            }
        }
    }

    static func makeService(for container: Container) throws -> APIInterface {
        let client = try container.client()
        let logger = try container.make(Logger.self)
        guard let hostname = Environment.get("api_hostname"),
            let port = Environment.get("api_port") else {
            throw Error.apiVariablesNeeded
        }

        guard let url = URL(string: "\(hostname):\(port)") else {
            throw Error.noUrl
        }
        return APIInterface(client: client, logger: logger, baseUrl: url)
    }
}

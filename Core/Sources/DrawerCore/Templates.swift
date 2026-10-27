import Foundation

public struct DiagramTemplate: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let symbol: String
    public let language: SpecLanguage
    public let spec: String

    public static let all: [DiagramTemplate] = [
        DiagramTemplate(name: "C4 Container", summary: "C4-PlantUML containers and relationships", symbol: "square.stack.3d.up",
                        language: .plantUML, spec: """
        @startuml
        !include <C4/C4_Container>
        title Internet Banking System

        Person(customer, "Personal Banking Customer", "A customer of the bank, with personal bank accounts.")
        System_Ext(mail, "E-mail System", "The internal Microsoft Exchange e-mail system.")

        System_Boundary(banking, "Internet Banking") {
          Container(web, "Web Application", "Java, Spring MVC", "Delivers the static content and the single page application.")
          Container(spa, "Single-Page App", "JavaScript, Angular", "Provides banking functionality in the browser.")
          Container(api, "API Application", "Java, Docker", "Provides banking functionality via a JSON/HTTPS API.")
          ContainerDb(db, "Database", "Oracle", "Stores user registration information, hashed credentials, access logs.")
        }

        Rel(customer, web, "Visits", "HTTPS")
        Rel(customer, spa, "Uses", "HTTPS")
        Rel(web, spa, "Delivers")
        Rel(spa, api, "Makes API calls to", "JSON/HTTPS")
        Rel(api, db, "Reads from and writes to", "JDBC")
        Rel(api, mail, "Sends e-mail using", "SMTP")
        @enduml
        """),
        DiagramTemplate(name: "C4 Context", summary: "Mermaid C4 system context", symbol: "globe",
                        language: .mermaid, spec: """
        C4Context
          title System Context for the Ordering Platform
          Person(shopper, "Shopper", "Buys products online")
          Person_Ext(support, "Support Agent")
          System(platform, "Ordering Platform", "Lets shoppers browse and order")
          System_Ext(payments, "Payment Provider", "Card processing")
          SystemDb_Ext(erp, "ERP", "Inventory and fulfilment")
          Rel(shopper, platform, "Places orders", "HTTPS")
          Rel(support, platform, "Manages orders")
          Rel(platform, payments, "Charges cards", "REST")
          Rel(platform, erp, "Syncs stock", "SFTP")
        """),
        DiagramTemplate(name: "Sequence", summary: "PlantUML sequence with activations and fragments", symbol: "arrow.left.arrow.right",
                        language: .plantUML, spec: """
        @startuml
        autonumber
        actor User
        participant "Web App" as web
        participant "Orders API" as api
        database "Orders DB" as db
        queue "Events" as events

        User -> web : Place order
        web -> api ++ : POST /orders
        api -> db : INSERT order
        db --> api : order id
        alt payment approved
          api -> events : OrderPlaced
          api --> web : 201 Created
        else payment declined
          api --> web : 402 Payment Required
        end
        deactivate api
        note right of events : Consumed by fulfilment
        web --> User : Confirmation
        @enduml
        """),
        DiagramTemplate(name: "Sequence (Mermaid)", summary: "Mermaid sequenceDiagram", symbol: "arrow.left.arrow.right.circle",
                        language: .mermaid, spec: """
        sequenceDiagram
          actor Alice
          participant Auth as Auth Service
          participant API
          Alice->>+Auth: Log in
          Auth-->>-Alice: Token
          loop Every minute
            Alice->>API: Poll status
            API--)Alice: Status
          end
          Note over Alice,API: Token sent in the Authorization header
          Alice-xAPI: Log out
        """),
        DiagramTemplate(name: "UML Class", summary: "PlantUML class diagram", symbol: "rectangle.split.3x1",
                        language: .plantUML, spec: """
        @startuml
        package Ordering {
          abstract class Entity {
            +id : UUID
            +createdAt : Date
          }
          class Order {
            +status : OrderStatus
            +total() : Money
            +submit()
          }
          class OrderLine {
            +quantity : Int
            +price : Money
          }
        }
        enum OrderStatus {
          DRAFT
          SUBMITTED
          SHIPPED
        }
        interface Repository {
          +save(order : Order)
          +find(id : UUID) : Order
        }
        class SqlRepository

        Entity <|-- Order
        Order "1" *-- "many" OrderLine : contains
        Order --> OrderStatus
        Repository <|.. SqlRepository
        SqlRepository ..> Order : persists
        @enduml
        """),
        DiagramTemplate(name: "Class (Mermaid)", summary: "Mermaid classDiagram", symbol: "rectangle.split.3x1.fill",
                        language: .mermaid, spec: """
        classDiagram
          direction TB
          class Animal {
            <<abstract>>
            +String name
            +int age
            +makeSound() void
          }
          class Duck {
            +swim()
          }
          class Fish {
            -int sizeInFeet
            -canEat()
          }
          class Zoo
          Animal <|-- Duck
          Animal <|-- Fish
          Zoo "1" o-- "*" Animal : houses
        """),
        DiagramTemplate(name: "ER (Mermaid)", summary: "Mermaid erDiagram with crow's foot notation", symbol: "tablecells",
                        language: .mermaid, spec: """
        erDiagram
          CUSTOMER ||--o{ ORDER : places
          ORDER ||--|{ LINE_ITEM : contains
          PRODUCT ||--o{ LINE_ITEM : "ordered in"
          CUSTOMER {
            uuid id PK
            string name
            string email UK
          }
          ORDER {
            uuid id PK
            uuid customer_id FK
            date placed_at
          }
          LINE_ITEM {
            uuid order_id FK
            uuid product_id FK
            int quantity
          }
          PRODUCT {
            uuid id PK
            string sku
            decimal price
          }
        """),
        DiagramTemplate(name: "ER (PlantUML)", summary: "PlantUML IE entities", symbol: "tablecells.fill",
                        language: .plantUML, spec: """
        @startuml
        entity Customer {
          *id : uuid <<PK>>
          --
          name : text
          email : text
        }
        entity Invoice {
          *id : uuid <<PK>>
          --
          *customer_id : uuid <<FK>>
          issued_on : date
        }
        entity Payment {
          *id : uuid <<PK>>
          amount : decimal
        }
        Customer ||--o{ Invoice
        Invoice ||--o{ Payment
        @enduml
        """),
        DiagramTemplate(name: "Flowchart", summary: "Mermaid flowchart", symbol: "arrow.triangle.branch",
                        language: .mermaid, spec: """
        flowchart TD
          start([Request received]) --> auth{Authenticated?}
          auth -->|yes| route[Route to service]
          auth -->|no| reject[Return 401]
          route --> cache[(Cache)]
          route --> svc(Service)
          svc --> done([Respond])
          reject --> done
        """),
        DiagramTemplate(name: "Components", summary: "PlantUML component / deployment", symbol: "shippingbox",
                        language: .plantUML, spec: """
        @startuml
        left to right direction
        actor User
        node "Kubernetes" as k8s {
          component "Gateway" as gw
          component "Orders Service" as orders
          queue "Events" as events
        }
        database "Postgres" as pg
        cloud "CDN" as cdn

        User --> cdn
        cdn --> gw : HTTPS
        gw --> orders
        orders --> pg
        orders ..> events : publishes
        @enduml
        """),
        DiagramTemplate(name: "Blank PlantUML", summary: "Empty @startuml document", symbol: "doc",
                        language: .plantUML, spec: "@startuml\n\n@enduml\n"),
        DiagramTemplate(name: "Blank Mermaid", summary: "Empty flowchart", symbol: "doc.fill",
                        language: .mermaid, spec: "flowchart TD\n"),
    ]
}

/// Starting points for a new document: an empty diagram of a chosen type, or that type's example.
public enum DiagramStarter {
    public static let families: [DiagramFamily] = [.c4, .classDiagram, .erDiagram, .sequence, .flowchart]

    public static func summary(_ family: DiagramFamily) -> String {
        switch family {
        case .c4: "People, systems, containers and components"
        case .classDiagram: "Classes, interfaces and their relationships"
        case .erDiagram: "Entities, attributes and cardinality"
        case .sequence: "Participants exchanging messages over time"
        case .flowchart: "Boxes and arrows, components and deployment"
        }
    }

    public static func symbol(_ family: DiagramFamily) -> String {
        switch family {
        case .c4: "square.stack.3d.up"
        case .classDiagram: "rectangle.split.3x1"
        case .erDiagram: "tablecells"
        case .sequence: "arrow.left.arrow.right"
        case .flowchart: "arrow.triangle.branch"
        }
    }

    /// An empty spec that already has the right diagram type (PlantUML has no type header, so a
    /// harmless type-specific directive marks it).
    public static func blankSpec(_ family: DiagramFamily, language: SpecLanguage) -> String {
        switch (language, family) {
        case (.plantUML, .c4): "@startuml\n!include <C4/C4_Container>\n\n@enduml\n"
        case (.plantUML, .classDiagram): "@startuml\nhide empty members\n\n@enduml\n"
        case (.plantUML, .erDiagram): "@startuml\nhide circle\n\n@enduml\n"
        case (.plantUML, .sequence): "@startuml\nhide footbox\n\n@enduml\n"
        case (.plantUML, .flowchart): "@startuml\n\n@enduml\n"
        case (.mermaid, .c4): "C4Container\n"
        case (.mermaid, .classDiagram): "classDiagram\n"
        case (.mermaid, .erDiagram): "erDiagram\n"
        case (.mermaid, .sequence): "sequenceDiagram\n"
        case (.mermaid, .flowchart): "flowchart TD\n"
        }
    }

    /// The example for a type, in the requested language when there is one.
    public static func example(_ family: DiagramFamily, language: SpecLanguage) -> DiagramTemplate? {
        let matching = DiagramTemplate.all.filter { SpecParser.parse($0.spec, language: $0.language).family == family && !$0.name.hasPrefix("Blank") }
        return matching.first { $0.language == language } ?? matching.first
    }
}

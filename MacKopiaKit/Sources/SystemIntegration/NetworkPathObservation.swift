package struct NetworkPathObservation: Sendable, Equatable {
    package let isExpensive: Bool?
    package let isConstrained: Bool?

    init(isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isExpensive = isSatisfied ? isExpensive : nil
        self.isConstrained = isSatisfied ? isConstrained : nil
    }

    package init(isExpensive: Bool? = nil, isConstrained: Bool? = nil) {
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

package protocol NetworkPathSampling: Sendable {
    func sampleNetwork() async throws -> NetworkPathObservation
}

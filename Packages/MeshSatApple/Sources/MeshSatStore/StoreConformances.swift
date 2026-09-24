// The GRDB DAOs are the engine's stores: the protocols in MeshSatEngine name exactly the DAO
// methods the Dispatcher, AccessEvaluator, FailoverResolver, AckTracker and CreditTracker call.
import MeshSatEngine

extension MessageDeliveryDao: DeliveryStore {}
extension AccessRuleDao: AccessRuleStore {}
extension ObjectGroupDao: ObjectGroupStore {}
extension FailoverGroupDao: FailoverGroupStore {}
extension IridiumCreditDao: IridiumCreditStore {}

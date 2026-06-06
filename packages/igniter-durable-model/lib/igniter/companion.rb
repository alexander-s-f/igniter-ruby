# frozen_string_literal: true

require_relative "durable_model"

module Igniter
  module Companion
    Record = DurableModel::Record
    History = DurableModel::History
    CommandActivity = DurableModel::CommandActivity
    CommandFlowDecision = DurableModel::CommandFlowDecision
    CommandFlowEvidenceArchive = DurableModel::CommandFlowEvidenceArchive
    Store = DurableModel::Store
    WriteReceipt = DurableModel::WriteReceipt
    AppendReceipt = DurableModel::AppendReceipt
    CommandActivityReceipt = DurableModel::CommandActivityReceipt
    CommandFlowDecisionReceipt = DurableModel::CommandFlowDecisionReceipt
    CommandFlowEvidenceArchiveReceipt = DurableModel::CommandFlowEvidenceArchiveReceipt
    CommandApplyReceipt = DurableModel::CommandApplyReceipt
    CommandIntent = DurableModel::CommandIntent
    CommandOperationPlan = DurableModel::CommandOperationPlan
    CommandActivityEvent = DurableModel::CommandActivityEvent
    CommandPolicyDecision = DurableModel::CommandPolicyDecision
    CommandLifecycle = DurableModel::CommandLifecycle
    CommandFlow = DurableModel::CommandFlow
    CommandFlowSlice = DurableModel::CommandFlowSlice
    CommandFlowMonitorResult = DurableModel::CommandFlowMonitorResult
    CommandFlowViewDescriptor = DurableModel::CommandFlowViewDescriptor
    CommandFlowView = DurableModel::CommandFlowView
    CommandFlowViewPin = DurableModel::CommandFlowViewPin
    CommandFlowDecisionReview = DurableModel::CommandFlowDecisionReview
    CommandFlowEvidenceProfile = DurableModel::CommandFlowEvidenceProfile
    CommandFlowEvidenceExport = DurableModel::CommandFlowEvidenceExport
    CommandFlowEvidenceExportVerification = DurableModel::CommandFlowEvidenceExportVerification

    def self.from_manifest(manifest, store: nil)
      DurableModel.from_manifest(manifest, store: store)
    end
  end
end

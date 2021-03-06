//
//  SenderController.swift
//  Telegram-Mac
//
//  Created by keepcoder on 31/10/2016.
//  Copyright © 2016 Telegram. All rights reserved.
//

import Cocoa
import TelegramCoreMac
import PostboxMac
import SwiftSignalKitMac
import AVFoundation
class MediaSenderContainer {
    let path:String
    let caption:String
    let isFile:Bool
    public init(path:String, caption:String = "", isFile:Bool = false) {
        self.path = path
        self.caption = caption
        self.isFile = isFile
    }
}

class VoiceSenderContainer : MediaSenderContainer {
    fileprivate let data:RecordedAudioData
    public init(data:RecordedAudioData) {
        self.data = data
        super.init(path: data.path)
        
    }
}

class VideoMessageSenderContainer : MediaSenderContainer {
    fileprivate let duration:Int
    fileprivate let size: CGSize
    public init(path:String, duration: Int, size: CGSize) {
        self.duration = duration
        self.size = size
        super.init(path: path, caption: "", isFile: false)
    }
}


class Sender: NSObject {
    
    private static func previewForFile(_ path: String, account: Account) -> [TelegramMediaImageRepresentation] {
        var preview:[TelegramMediaImageRepresentation] = []
        
        let options = NSMutableDictionary()
        options.setValue(90 as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
        options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
        
        let colorQuality: Float = 0.6
        options.setObject(colorQuality as NSNumber, forKey: kCGImageDestinationLossyCompressionQuality as NSString)

        
        if path.nsstring.pathExtension.hasPrefix("mp4") {
            let asset = AVAsset(url: URL(fileURLWithPath: path))
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.maximumSize = CGSize(width: 200, height: 200)
            imageGenerator.appliesPreferredTrackTransform = true
            let fullSizeImage = try? imageGenerator.copyCGImage(at: CMTime(seconds: 0.0, preferredTimescale: asset.duration.timescale), actualTime: nil)
            
            if let image = fullSizeImage {
                
                let mutableData: CFMutableData = NSMutableData() as CFMutableData
                if let colorDestination = CGImageDestinationCreateWithData(mutableData, kUTTypeJPEG, 1, options) {
                    CGImageDestinationSetProperties(colorDestination, nil)
                    
                    CGImageDestinationAddImage(colorDestination, image, options as CFDictionary)
                    if CGImageDestinationFinalize(colorDestination) {
                        let resource = LocalFileMediaResource(fileId: arc4random64())
                        account.postbox.mediaBox.storeResourceData(resource.id, data: mutableData as Data)
                        preview.append(TelegramMediaImageRepresentation(dimensions: image.size, resource: resource))
                    }
                }
                
                
            }
            
           
        } else if let thumbData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            
            if let imageSource = CGImageSourceCreateWithData(thumbData as CFData, options) {
                if let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) {
                    let imageRep = NSBitmapImageRep(cgImage: image)
                    let options: [NSBitmapImageRep.PropertyKey: Any] = [NSBitmapImageRep.PropertyKey.compressionFactor: 0.6]
                    let compressedData: Data? = imageRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: options)
                    
                    if let compressedData = compressedData {
                        let resource = LocalFileMediaResource(fileId: arc4random64())
                        account.postbox.mediaBox.storeResourceData(resource.id, data: compressedData)
                        preview.append(TelegramMediaImageRepresentation(dimensions: image.size, resource: resource))
                    }
                    
                }
                
            }
        }
        return preview
    }

    public static func enqueue( input:ChatTextInputState, account:Account, peerId:PeerId, replyId:MessageId?, disablePreview:Bool = false) ->Signal<[MessageId?],NoError> {
        
        var inset:Int = 0
        
        var input:ChatTextInputState = input
        var emojis = input.inputText.emojis.reduce("", {$0 + $1 + ","}).fixed.components(separatedBy: ",")
        emojis.removeLast()
        if input.attributes.isEmpty {
            input = ChatTextInputState(inputText: input.inputText.trimmed)
        }
        let mapped = cut_long_message( input.inputText, 4096).map { message -> EnqueueMessage in
            let subState = input.subInputState(from: NSMakeRange(inset, message.length))
            inset += message.length
            
            var attributes:[MessageAttribute] = [TextEntitiesMessageAttribute(entities: subState.messageTextEntities)]
            if disablePreview {
                attributes.append(OutgoingContentInfoMessageAttribute(flags: [.disableLinkPreviews]))
            }
            if FastSettings.isChannelMessagesMuted(peerId) {
                attributes.append(NotificationInfoMessageAttribute(flags: [.muted]))
            }
            
            
            return EnqueueMessage.message(text: subState.inputText, attributes: attributes, media: nil, replyToMessageId: replyId)
        }
        
        return enqueueMessages(account: account, peerId: peerId, messages: mapped) |> mapToSignal { value in
            if !emojis.isEmpty {
                return saveUsedEmoji(emojis, postbox: account.postbox) |> map {
                    return value
                }
            }
            return .single(value)
        } |> deliverOnMainQueue
        
    }
    
    public static func enqueue(message:EnqueueMessage, account:Account, peerId:PeerId) ->Signal<[MessageId?],NoError> {
        return  enqueueMessages(account: account, peerId: peerId, messages: [message])
            |> deliverOnMainQueue
        
    }
    
    private static func generateMedia(for container:MediaSenderContainer, account: Account) -> Signal<(Media,String),Void> {
        return Signal { (subscriber) in
            
            let path = container.path
            var media:Media!
            
            var randomId: Int64 = 0
            arc4random_buf(&randomId, 8)
            
            func makeFileMedia(_ isMedia: Bool) {
                let mimeType = MIMEType(path.nsstring.pathExtension)
                let attrs:[TelegramMediaFileAttribute] = fileAttributes(for:mimeType, path:path, isMedia: isMedia)
                let resource = LocalFileReferenceMediaResource(localFilePath:path,randomId:randomId, size: fileSize(path))
                media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: randomId), resource: resource, previewRepresentations: [], mimeType: mimeType, size: nil, attributes: attrs)
            }
            
            if !container.isFile {
                let mimeType = MIMEType(path.nsstring.pathExtension.lowercased())
                if let container = container as? VoiceSenderContainer {
                    let mimeType = voiceMime
                    var attrs:[TelegramMediaFileAttribute] = []
                    var memoryWaveform:MemoryBuffer?
                    if let waveformData = container.data.waveform {
                        memoryWaveform = MemoryBuffer(data: waveformData)
                    }
                    attrs.append(.Audio(isVoice: true, duration: Int(container.data.duration), title: nil, performer: nil, waveform: memoryWaveform))
                    media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: randomId), resource: LocalFileReferenceMediaResource(localFilePath:path,randomId: randomId, isUniquelyReferencedTemporaryFile: true, size: fileSize(path)), previewRepresentations: [], mimeType: mimeType, size: nil, attributes: attrs)
                } else if let container = container as? VideoMessageSenderContainer {
                    var attrs:[TelegramMediaFileAttribute] = []

                    attrs.append(TelegramMediaFileAttribute.Video(duration: Int(container.duration), size: container.size, flags: [.instantRoundVideo]))
                    media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: randomId), resource: LocalFileReferenceMediaResource(localFilePath:path,randomId: randomId, isUniquelyReferencedTemporaryFile: true, size: fileSize(path)), previewRepresentations: previewForFile(path, account: account), mimeType: mimeType, size: nil, attributes: attrs)

                } else if mimeType.hasPrefix("image/") && !mimeType.hasSuffix("gif"), let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                   
                    let options = NSMutableDictionary()
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailWithTransform as String)
                    options.setValue(1280 as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)

                    
                    if let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) {
                        
                        let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options)
                        
                        if let image = image {
                           
                            let size = image.size
                            
                            if size.width / 10 > size.height || size.height < 40 {
                                makeFileMedia(true)
                            } else {
                                let imageRep = NSBitmapImageRep(cgImage: image)
                                let options: [NSBitmapImageRep.PropertyKey: Any] = [NSBitmapImageRep.PropertyKey.compressionFactor: Float(0.83)]
                                let path = NSTemporaryDirectory() + "tg_image_\(arc4random()).jpeg"
                                try? imageRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: options)?.write(to: URL(fileURLWithPath: path))
                                
                                
                                let scaledSize = size.aspectFilled(CGSize(width: 1280.0, height: 1280.0))
                                let resource = LocalFileReferenceMediaResource(localFilePath:path,randomId:randomId, isUniquelyReferencedTemporaryFile: true)
                                
                                media = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: randomId), representations: [TelegramMediaImageRepresentation(dimensions: scaledSize, resource: resource)])
                            }
                            
                        } else {
                            makeFileMedia(true)
                        }
                    } else {
                       makeFileMedia(true)
                    }
                    
                    
                } else if mimeType.hasSuffix("gif") {
                    let attrs:[TelegramMediaFileAttribute] = fileAttributes(for:mimeType, path:path, isMedia: true)
                    
                    
                    
                    
                    media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: randomId), resource: LocalFileGifMediaResource(randomId: arc4random64(), path: container.path), previewRepresentations: previewForFile(path, account: account), mimeType: "video/mp4", size: nil, attributes: attrs)
                } else {
                    makeFileMedia(true)
                }
            } else {
                makeFileMedia(false)
            }
            
            
            
            subscriber.putNext((media,container.caption))
            subscriber.putCompletion()
            
            return EmptyDisposable
            
        } |> runOn(resourcesQueue)
    }
    
    public static func fileAttributes(for mime:String, path:String, isMedia:Bool = false) -> [TelegramMediaFileAttribute] {
        var attrs:[TelegramMediaFileAttribute] = []
        
        if mime.hasPrefix("audio/") {
            //AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let tags = audioTags(asset)
            let parts = path.nsstring.lastPathComponent.components(separatedBy: "-")
            let defaultTitle:String
            let defaultPerformer:String
            if let title = tags["title"], let performer = tags["performer"] {
                defaultTitle = title
                defaultPerformer = performer
            } else if parts.count == 2 {
                defaultTitle = parts[0]
                defaultPerformer = parts[1]
            } else {
                defaultTitle = "Untitled"
                defaultPerformer = "Unknown Artist"
            }
            attrs.append(.Audio(isVoice: false, duration: Int(CMTimeGetSeconds(asset.duration)), title: defaultTitle, performer: defaultPerformer, waveform: nil))
        }
        
        if mime.hasPrefix("video"), isMedia {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let video = asset.tracks(withMediaType: AVMediaType.video).first
            let audio = asset.tracks(withMediaType: AVMediaType.audio).first
            if let video = video {
                attrs.append(TelegramMediaFileAttribute.Video(duration: Int(CMTimeGetSeconds(asset.duration)), size: video.naturalSize, flags: []))
            }
            if audio == nil {
                attrs.append(TelegramMediaFileAttribute.Animated)
            }
        }
        
        if mime.hasSuffix("gif"), isMedia {
            attrs.append(TelegramMediaFileAttribute.Video(duration: 0, size:TGGifConverter.gifDimensionSize(path), flags: []))
            attrs.append(TelegramMediaFileAttribute.Animated)
            attrs.append(TelegramMediaFileAttribute.FileName(fileName: path.nsstring.lastPathComponent.nsstring.deletingPathExtension.appending(".mp4")))

        } else {
            attrs.append(TelegramMediaFileAttribute.FileName(fileName: path.nsstring.lastPathComponent))
        }
        return attrs
    }
    
    public static func forwardMessages(messageIds:[MessageId], account:Account, peerId:PeerId) -> Signal<[MessageId?], NoError> {
        
        var fwdMessages:[EnqueueMessage] = []
        
        let sorted = messageIds.sorted(by: >)
        
        
        for msgId in sorted {
            fwdMessages.append(EnqueueMessage.forward(source: msgId))
        }
        return enqueueMessages(account: account, peerId: peerId, messages: fwdMessages.reversed())
    }
    
    public static func shareContact(account:Account, peerId:PeerId, contact:TelegramUser) -> Signal<[MessageId?], NoError>  {
        
        var attributes:[MessageAttribute] = []
        if FastSettings.isChannelMessagesMuted(peerId) {
            attributes.append(NotificationInfoMessageAttribute(flags: [.muted]))
        }
        
        return enqueueMessages(account: account, peerId: peerId, messages: [EnqueueMessage.message(text: "", attributes: attributes, media: TelegramMediaContact(firstName: contact.firstName ?? "", lastName: contact.lastName ?? "", phoneNumber: contact.phone ?? "", peerId: contact.id), replyToMessageId: nil)])
    }
    
    public static func enqueue(media:[MediaSenderContainer], account:Account, peerId:PeerId, chatInteraction:ChatInteraction) ->Signal<[MessageId?],NoError> {
        var senders:[Signal<[MessageId?],NoError>] = []
        
        var attributes:[MessageAttribute] = []
        if FastSettings.isChannelMessagesMuted(peerId) {
            attributes.append(NotificationInfoMessageAttribute(flags: [.muted]))
        }
        
        for path in media {
            senders.append(generateMedia(for: path, account: account) |> mapToSignal { media, caption -> Signal< [MessageId?], NoError> in
                
                return enqueueMessages(account: account, peerId: peerId, messages: [EnqueueMessage.message(text: caption, attributes:attributes, media: media, replyToMessageId: chatInteraction.presentation.interfaceState.replyMessageId)])

            })
        }
        
        return combineLatest(senders) |> deliverOnMainQueue |> mapToSignal { results -> Signal<[MessageId?], NoError> in
            
            let result = results.reduce([], { messageIds, current -> [MessageId?] in
                return messageIds + current
            })
            
            return .single(result)
            
        }  |> take(1) |> afterCompleted {
            chatInteraction.update({$0.updatedInterfaceState({$0.withUpdatedReplyMessageId(nil)})})
        }
    }
    
    public static func enqueue(media:TelegramMediaFile, account:Account, peerId:PeerId, chatInteraction:ChatInteraction) ->Signal<[MessageId?],NoError> {
        
        var attributes:[MessageAttribute] = []
        if FastSettings.isChannelMessagesMuted(peerId) {
            attributes.append(NotificationInfoMessageAttribute(flags: [.muted]))
        }
        
        return enqueueMessages(account: account, peerId: peerId, messages: [EnqueueMessage.message(text: "", attributes: attributes, media: media, replyToMessageId: chatInteraction.presentation.interfaceState.replyMessageId)]) |> deliverOnMainQueue |> afterNext({ (value) -> Void in
            chatInteraction.update({$0.updatedInterfaceState({$0.withUpdatedReplyMessageId(nil)})})
        })
    }
    
    
}

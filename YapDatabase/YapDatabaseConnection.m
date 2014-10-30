
#import "YapDatabaseConnection.h"
#import "YapDatabaseConnectionState.h"
#import "YapDatabasePrivate.h"
#import "YapDatabaseExtensionPrivate.h"

#import "YapCollectionKey.h"
#import "YapCache.h"
#import "YapTouch.h"
#import "YapNull.h"
#import "YapSet.h"

#import "YapDatabaseString.h"
#import "YapDatabaseLogging.h"

#import <objc/runtime.h>
#import <libkern/OSAtomic.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_INFO;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif

static NSUInteger const UNLIMITED_CACHE_LIMIT = 0;
static NSUInteger const MIN_KEY_CACHE_LIMIT   = 500;

static NSString *const ExtKey_class = @"class";

typedef BOOL (*IMP_NSThread_isMainThread)(id, SEL);
static IMP_NSThread_isMainThread ydb_NSThread_isMainThread;
static Class ydb_NSThread_Class;

NS_INLINE BOOL YDBIsMainThread()
{
	return ydb_NSThread_isMainThread(ydb_NSThread_Class, @selector(isMainThread));
}

@implementation YapDatabaseConnection {
@private
	
	sqlite3_stmt *beginTransactionStatement;
	sqlite3_stmt *commitTransactionStatement;
	sqlite3_stmt *rollbackTransactionStatement;
	
	sqlite3_stmt *yapGetDataForKeyStatement;   // Against "yap" database, for internal use
	sqlite3_stmt *yapSetDataForKeyStatement;   // Against "yap" database, for internal use
	sqlite3_stmt *yapRemoveForKeyStatement;    // Against "yap" database, for internal use
	sqlite3_stmt *yapRemoveExtensionStatement; // Against "yap" database, for internal use
	
	sqlite3_stmt *getCollectionCountStatement;
	sqlite3_stmt *getKeyCountForCollectionStatement;
	sqlite3_stmt *getKeyCountForAllStatement;
	sqlite3_stmt *getCountForRowidStatement;
	sqlite3_stmt *getRowidForKeyStatement;
	sqlite3_stmt *getKeyForRowidStatement;
	sqlite3_stmt *getDataForRowidStatement;
	sqlite3_stmt *getMetadataForRowidStatement;
	sqlite3_stmt *getAllForRowidStatement;
	sqlite3_stmt *getDataForKeyStatement;
	sqlite3_stmt *getMetadataForKeyStatement;
	sqlite3_stmt *getAllForKeyStatement;
	sqlite3_stmt *insertForRowidStatement;
	sqlite3_stmt *updateAllForRowidStatement;
	sqlite3_stmt *updateObjectForRowidStatement;
	sqlite3_stmt *updateMetadataForRowidStatement;
	sqlite3_stmt *removeForRowidStatement;
	sqlite3_stmt *removeCollectionStatement;
	sqlite3_stmt *removeAllStatement;
	sqlite3_stmt *enumerateCollectionsStatement;
	sqlite3_stmt *enumerateCollectionsForKeyStatement;
	sqlite3_stmt *enumerateKeysInCollectionStatement;
	sqlite3_stmt *enumerateKeysInAllCollectionsStatement;
	sqlite3_stmt *enumerateKeysAndMetadataInCollectionStatement;
	sqlite3_stmt *enumerateKeysAndMetadataInAllCollectionsStatement;
	sqlite3_stmt *enumerateKeysAndObjectsInCollectionStatement;
	sqlite3_stmt *enumerateKeysAndObjectsInAllCollectionsStatement;
	sqlite3_stmt *enumerateRowsInCollectionStatement;
	sqlite3_stmt *enumerateRowsInAllCollectionsStatement;
	
	OSSpinLock lock;
	BOOL writeQueueSuspended;
	BOOL activeReadWriteTransaction;
}

+ (void)load
{
	static BOOL loaded = NO;
	if (!loaded)
	{
		// Method swizzle:
		// Both 'extension:' and 'ext:' are designed to be the same method (with ext: shorthand for extension:).
		// So swap out the ext: method to point to extension:.
		
		Method extMethod = class_getInstanceMethod([self class], @selector(ext:));
		IMP extensionIMP = class_getMethodImplementation([self class], @selector(extension:));
		
		method_setImplementation(extMethod, extensionIMP);
		loaded = YES;
		
		// Optimized invocation of [NSThread isMainThread].
		// Benchmarks seem to indicate:
		// - ~30% performance improvement on the main thread
		// - ~50% performance improvement on background thread(s)
		
		ydb_NSThread_isMainThread = (IMP_NSThread_isMainThread)[NSThread methodForSelector:@selector(isMainThread)];
		ydb_NSThread_Class = [NSThread class];
	}
}

- (id)initWithDatabase:(YapDatabase *)inDatabase
{
	if ((self = [super init]))
	{
		database = inDatabase;
		connectionQueue = dispatch_queue_create("YapDatabaseConnection", NULL);
		
		IsOnConnectionQueueKey = &IsOnConnectionQueueKey;
		dispatch_queue_set_specific(connectionQueue, IsOnConnectionQueueKey, IsOnConnectionQueueKey, NULL);
		
	#if DEBUG
		throwExceptionsForImplicitlyEndingLongLivedReadTransaction = YES;
	#else
		throwExceptionsForImplicitlyEndingLongLivedReadTransaction = NO;
	#endif
		
		pendingChangesets = [[NSMutableArray alloc] init];
		processedChangesets = [[NSMutableArray alloc] init];
		
		sharedKeySetForInternalChangeset = [NSDictionary sharedKeySetForKeys:[self internalChangesetKeys]];
		sharedKeySetForExternalChangeset = [NSDictionary sharedKeySetForKeys:[self externalChangesetKeys]];
		sharedKeySetForExtensions        = [NSDictionary sharedKeySetForKeys:@[]];
		
		extensions = [[NSMutableDictionary alloc] init];
		
		YapDatabaseConnectionDefaults *defaults = [database connectionDefaults];
		
		NSUInteger keyCacheLimit = MIN_KEY_CACHE_LIMIT;
		
		if (defaults.objectCacheEnabled)
		{
			objectCacheLimit = defaults.objectCacheLimit;
			objectCache = [[YapCache alloc] initWithKeyClass:[YapCollectionKey class]
			                                    keyCallbacks:[YapCollectionKey keyCallbacks]
			                                      countLimit:objectCacheLimit];
			
			if (keyCacheLimit != UNLIMITED_CACHE_LIMIT)
			{
				if (objectCacheLimit == UNLIMITED_CACHE_LIMIT)
					keyCacheLimit = UNLIMITED_CACHE_LIMIT;
				else
					keyCacheLimit = MAX(keyCacheLimit, objectCacheLimit);
			}
		}
		if (defaults.metadataCacheEnabled)
		{
			metadataCacheLimit = defaults.metadataCacheLimit;
			metadataCache = [[YapCache alloc] initWithKeyClass:[YapCollectionKey class]
			                                      keyCallbacks:[YapCollectionKey keyCallbacks]
		 	                                        countLimit:metadataCacheLimit];
			
			if (keyCacheLimit != UNLIMITED_CACHE_LIMIT)
			{
				if (metadataCacheLimit == UNLIMITED_CACHE_LIMIT)
					keyCacheLimit = UNLIMITED_CACHE_LIMIT;
				else
					keyCacheLimit = MAX(keyCacheLimit, objectCacheLimit);
			}
		}
		
		objectPolicy = defaults.objectPolicy;
		metadataPolicy = defaults.metadataPolicy;
		
	#if YapDatabaseEnforcePermittedTransactions
		self.permittedTransactions = YDB_AnyTransaction;
	#endif
		
		keyCache = [[YapCache alloc] initWithKeyClass:[NSNumber class] countLimit:keyCacheLimit];
		
		#if TARGET_OS_IPHONE
		self.autoFlushMemoryFlags = defaults.autoFlushMemoryFlags;
		#endif
		
		lock = OS_SPINLOCK_INIT;
		
		db = [database connectionPoolDequeue];
		if (db == NULL)
		{
			// Open the database connection.
			//
			// We use SQLITE_OPEN_NOMUTEX to use the multi-thread threading mode,
			// as we will be serializing access to the connection externally.
			
			int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE;
			
			int status = sqlite3_open_v2([database.databasePath UTF8String], &db, flags, NULL);
			if (status != SQLITE_OK)
			{
				// Sometimes the open function returns a db to allow us to query it for the error message
				if (db) {
					YDBLogWarn(@"Error opening database: %d %s", status, sqlite3_errmsg(db));
				}
				else {
					YDBLogError(@"Error opening database: %d", status);
				}
			}
			else
			{
				// Set configurable pragmas
				
				YapDatabasePragmaSynchronous pragmaSynchronous = database.options.pragmaSynchronous;
				
				if (pragmaSynchronous == YapDatabasePragmaSynchronous_Off ||
				    pragmaSynchronous == YapDatabasePragmaSynchronous_Normal)
				{
					char *pragma_stmt = NULL;
					
					if (pragmaSynchronous == YapDatabasePragmaSynchronous_Off)
						pragma_stmt = "PRAGMA synchronous = OFF;";
					else
						pragma_stmt = "PRAGMA synchronous = NORMAL;";
				
					status = sqlite3_exec(db, pragma_stmt, NULL, NULL, NULL);
					if (status != SQLITE_OK)
					{
						YDBLogError(@"Error setting PRAGMA synchronous: %d %s", status, sqlite3_errmsg(db));
					}
				}
				
				// Disable autocheckpointing.
				//
				// YapDatabase has its own optimized checkpointing algorithm built-in.
				// It knows the state of every active connection for the database,
				// so it can invoke the checkpoint methods at the precise time
				// in which a checkpoint can be most effective.
				
				sqlite3_wal_autocheckpoint(db, 0);
				
				// Edge case workaround.
				//
				// If there's an active checkpoint operation,
				// then the very first time we call sqlite3_prepare_v2 on this db,
				// we sometimes get a SQLITE_BUSY error.
				//
				// This only seems to happen once, and only during the very first use of the db instance.
				// I'm still tyring to figure out exactly why this is.
				// For now I'm setting a busy timeout as a temporary workaround.
				//
				// Note: I've also tested setting a busy_handler which logs the number of times its called.
				// And in all my testing, I've only seen the busy_handler called once per db.
				
				sqlite3_busy_timeout(db, 50); // milliseconds
                
#ifdef SQLITE_HAS_CODEC
                // Configure SQLCipher encryption for the new database connection.
                [database configureEncryptionForDatabase:db];
                
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(processEncryptionKeyChangeNotification:) name:YapDatabaseEncryptionKeyChangeNotification object:database];
#endif
			}
		}
		
		#if TARGET_OS_IPHONE
		[[NSNotificationCenter defaultCenter] addObserver:self
		                                         selector:@selector(didReceiveMemoryWarning:)
		                                             name:UIApplicationDidReceiveMemoryWarningNotification
		                                           object:nil];
		#endif
	}
	return self;
}

/**
 * This method will be invoked before any other method.
 * It can be used to do any setup that may be needed.
**/
- (void)prepare
{
	// This method is invoked from our connectionQueue, within the snapshotQueue.
	// Don't do anything expensive here that might tie up the snapshotQueue.
	
	snapshot               = [database snapshot];
	registeredExtensions   = [database registeredExtensions];
	registeredMemoryTables = [database registeredMemoryTables];
	extensionsOrder        = [database extensionsOrder];
	extensionDependencies  = [database extensionDependencies];
	
	extensionsReady = ([registeredExtensions count] == 0);
}

- (void)dealloc
{
	YDBLogVerbose(@"Dealloc <YapDatabaseConnection %p: databaseName=%@>",
	              self, [database.databasePath lastPathComponent]);
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		if (longLivedReadTransaction) {
			[self postReadTransaction:longLivedReadTransaction];
			longLivedReadTransaction = nil;
		}
	}};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[extensions removeAllObjects];
	
	[self _flushStatements];
	
	if (db)
	{
		if (![database connectionPoolEnqueue:db])
		{
			int status = sqlite3_close(db);
			if (status != SQLITE_OK)
			{
				YDBLogError(@"Error in sqlite_close: %d %s", status, sqlite3_errmsg(db));
			}
		}
		
		db = NULL;
	}
	
	[database removeConnection:self];
	
#if !OS_OBJECT_USE_OBJC
	if (connectionQueue)
		dispatch_release(connectionQueue);
#endif
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Memory
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)_flushStatements
{
	sqlite_finalize_null(&beginTransactionStatement);
	sqlite_finalize_null(&commitTransactionStatement);
	sqlite_finalize_null(&rollbackTransactionStatement);
	
	sqlite_finalize_null(&yapGetDataForKeyStatement);
	sqlite_finalize_null(&yapSetDataForKeyStatement);
	sqlite_finalize_null(&yapRemoveForKeyStatement);
	sqlite_finalize_null(&yapRemoveExtensionStatement);
	
	sqlite_finalize_null(&getCollectionCountStatement);
	sqlite_finalize_null(&getKeyCountForCollectionStatement);
	sqlite_finalize_null(&getKeyCountForAllStatement);
	sqlite_finalize_null(&getCountForRowidStatement);
	sqlite_finalize_null(&getRowidForKeyStatement);
	sqlite_finalize_null(&getKeyForRowidStatement);
	sqlite_finalize_null(&getDataForRowidStatement);
	sqlite_finalize_null(&getMetadataForRowidStatement);
	sqlite_finalize_null(&getAllForRowidStatement);
	sqlite_finalize_null(&getDataForKeyStatement);
	sqlite_finalize_null(&getMetadataForKeyStatement);
	sqlite_finalize_null(&getAllForKeyStatement);
	sqlite_finalize_null(&insertForRowidStatement);
	sqlite_finalize_null(&updateAllForRowidStatement);
	sqlite_finalize_null(&updateObjectForRowidStatement);
	sqlite_finalize_null(&updateMetadataForRowidStatement);
	sqlite_finalize_null(&removeForRowidStatement);
	sqlite_finalize_null(&removeCollectionStatement);
	sqlite_finalize_null(&removeAllStatement);
	sqlite_finalize_null(&enumerateCollectionsStatement);
	sqlite_finalize_null(&enumerateCollectionsForKeyStatement);
	sqlite_finalize_null(&enumerateKeysInCollectionStatement);
	sqlite_finalize_null(&enumerateKeysInAllCollectionsStatement);
	sqlite_finalize_null(&enumerateKeysAndMetadataInCollectionStatement);
	sqlite_finalize_null(&enumerateKeysAndMetadataInAllCollectionsStatement);
	sqlite_finalize_null(&enumerateKeysAndObjectsInCollectionStatement);
	sqlite_finalize_null(&enumerateKeysAndObjectsInAllCollectionsStatement);
	sqlite_finalize_null(&enumerateRowsInCollectionStatement);
	sqlite_finalize_null(&enumerateRowsInAllCollectionsStatement);
}

- (void)_flushMemoryWithFlags:(YapDatabaseConnectionFlushMemoryFlags)flags
{
	if (flags & YapDatabaseConnectionFlushMemoryFlags_Caches)
	{
		[keyCache removeAllObjects];
		[objectCache removeAllObjects];
		[metadataCache removeAllObjects];
	}
	
	if (flags & YapDatabaseConnectionFlushMemoryFlags_Statements)
	{
		[self _flushStatements];
	}
	
	[extensions enumerateKeysAndObjectsUsingBlock:^(id extNameObj, id extConnectionObj, BOOL *stop) {
		
		[(YapDatabaseExtensionConnection *)extConnectionObj _flushMemoryWithFlags:flags];
	}];
}

/**
 * This method may be used to flush the internal caches used by the connection,
 * as well as flushing pre-compiled sqlite statements.
 * Depending upon how often you use the database connection,
 * you may want to be more or less aggressive on how much stuff you flush.
 *
 * YapDatabaseConnectionFlushMemoryLevelNone (0):
 *     No-op. Doesn't flush any caches or anything from internal memory.
 *
 * YapDatabaseConnectionFlushMemoryLevelMild (1):
 *     Flushes the object cache and metadata cache.
 *
 * YapDatabaseConnectionFlushMemoryLevelModerate (2):
 *     Mild plus drops less common pre-compiled sqlite statements.
 *
 * YapDatabaseConnectionFlushMemoryLevelFull (3):
 *     Full flush of all caches and removes all pre-compiled sqlite statements.
**/
- (void)flushMemoryWithFlags:(YapDatabaseConnectionFlushMemoryFlags)flags
{
	dispatch_block_t block = ^{
		
		[self _flushMemoryWithFlags:flags];
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

#if TARGET_OS_IPHONE
- (void)didReceiveMemoryWarning:(NSNotification *)notification
{
	[self flushMemoryWithFlags:[self autoFlushMemoryFlags]];
}
#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Properties
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@synthesize database = database;
@synthesize name = _name;

#if YapDatabaseEnforcePermittedTransactions
@synthesize permittedTransactions = _mustUseAtomicProperty_permittedTransactions;
#endif

#if TARGET_OS_IPHONE
@synthesize autoFlushMemoryFlags;
#endif

- (BOOL)objectCacheEnabled
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
		result = (objectCache != nil);
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return result;
}

- (void)setObjectCacheEnabled:(BOOL)flag
{
	dispatch_block_t block = ^{
		
		if (flag) // Enabled
		{
			if (objectCache == nil)
			{
				objectCache = [[YapCache alloc] initWithKeyClass:[YapCollectionKey class]
				                                    keyCallbacks:[YapCollectionKey keyCallbacks]
				                                      countLimit:objectCacheLimit];
			}
		}
		else // Disabled
		{
			objectCache = nil;
		}
		
		[self updateKeyCacheLimit];
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

- (NSUInteger)objectCacheLimit
{
	__block NSUInteger result = 0;
	
	dispatch_block_t block = ^{
		result = objectCacheLimit;
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return result;
}

- (void)setObjectCacheLimit:(NSUInteger)newObjectCacheLimit
{
	dispatch_block_t block = ^{
		
		if (objectCacheLimit != newObjectCacheLimit)
		{
			objectCacheLimit = newObjectCacheLimit;
			
			if (objectCache == nil)
			{
				// Limit changed, but objectCache is still disabled
			}
			else
			{
				objectCache.countLimit = objectCacheLimit;
				[self updateKeyCacheLimit];
			}
		}
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

- (BOOL)metadataCacheEnabled
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
		result = (metadataCache != nil);
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return result;
}

- (void)setMetadataCacheEnabled:(BOOL)flag
{
	dispatch_block_t block = ^{
		
		if (flag) // Enabled
		{
			if (metadataCache == nil)
			{
				metadataCache = [[YapCache alloc] initWithKeyClass:[YapCollectionKey class]
				                                      keyCallbacks:[YapCollectionKey keyCallbacks]
				                                        countLimit:metadataCacheLimit];
			}
		}
		else // Disabled
		{
			metadataCache = nil;
		}
		
		[self updateKeyCacheLimit];
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

- (NSUInteger)metadataCacheLimit
{
	__block NSUInteger result = 0;
	
	dispatch_block_t block = ^{
		result = metadataCacheLimit;
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return result;
}

- (void)setMetadataCacheLimit:(NSUInteger)newMetadataCacheLimit
{
	dispatch_block_t block = ^{
		
		if (metadataCacheLimit != newMetadataCacheLimit)
		{
			metadataCacheLimit = newMetadataCacheLimit;
			
			if (metadataCache == nil)
			{
				// Limit changed but metadataCache still disabled
			}
			else
			{
				metadataCache.countLimit = metadataCacheLimit;
				[self updateKeyCacheLimit];
			}
		}
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

- (YapDatabasePolicy)objectPolicy
{
	__block YapDatabasePolicy policy = YapDatabasePolicyContainment;
	
	dispatch_block_t block = ^{
		policy = objectPolicy;
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return policy;
}

- (void)setObjectPolicy:(YapDatabasePolicy)newObjectPolicy
{
	dispatch_block_t block = ^{
		
		// sanity check
		switch (newObjectPolicy)
		{
			case YapDatabasePolicyContainment :
			case YapDatabasePolicyShare       :
			case YapDatabasePolicyCopy        : objectPolicy = newObjectPolicy; break;
			default                           : objectPolicy = YapDatabasePolicyContainment;
		}
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

- (YapDatabasePolicy)metadataPolicy
{
	__block YapDatabasePolicy policy = YapDatabasePolicyContainment;
	
	dispatch_block_t block = ^{
		policy = metadataPolicy;
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return policy;
}

- (void)setMetadataPolicy:(YapDatabasePolicy)newMetadataPolicy
{
	dispatch_block_t block = ^{
		
		// sanity check
		switch (newMetadataPolicy)
		{
			case YapDatabasePolicyContainment :
			case YapDatabasePolicyShare       :
			case YapDatabasePolicyCopy        : metadataPolicy = newMetadataPolicy; break;
			default                           : metadataPolicy = YapDatabasePolicyContainment;
		}
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

- (uint64_t)snapshot
{
	__block uint64_t result = 0;
	
	dispatch_block_t block = ^{
		result = snapshot;
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#ifdef SQLITE_HAS_CODEC
// When the encryption key changes, make sure to change the
// key for every connection
- (void)processEncryptionKeyChangeNotification:(NSNotification*)notification {
    [database configureEncryptionForDatabase:db];
}
#endif

- (void)updateKeyCacheLimit
{
	NSUInteger keyCacheLimit = MIN_KEY_CACHE_LIMIT;
	
	if (keyCacheLimit != UNLIMITED_CACHE_LIMIT)
	{
		if (objectCache)
		{
			if (objectCacheLimit == UNLIMITED_CACHE_LIMIT)
				keyCacheLimit = UNLIMITED_CACHE_LIMIT;
			else
				keyCacheLimit = MAX(keyCacheLimit, objectCacheLimit);
		}
	}
	
	if (keyCacheLimit != UNLIMITED_CACHE_LIMIT)
	{
		if (metadataCache)
		{
			if (objectCacheLimit == UNLIMITED_CACHE_LIMIT)
				keyCacheLimit = UNLIMITED_CACHE_LIMIT;
			else
				keyCacheLimit = MAX(keyCacheLimit, objectCacheLimit);
		}
	}
	
	keyCache.countLimit = keyCacheLimit;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Statements
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (sqlite3_stmt *)beginTransactionStatement
{
	sqlite3_stmt **statement = &beginTransactionStatement;
	if (*statement == NULL)
	{
		char *stmt = "BEGIN TRANSACTION;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)commitTransactionStatement
{
	sqlite3_stmt **statement = &commitTransactionStatement;
	if (*statement == NULL)
	{
		char *stmt = "COMMIT TRANSACTION;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)rollbackTransactionStatement
{
	sqlite3_stmt **statement = &rollbackTransactionStatement;
	if (*statement == NULL)
	{
		char *stmt = "ROLLBACK TRANSACTION;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)yapGetDataForKeyStatement
{
	sqlite3_stmt **statement = &yapGetDataForKeyStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"data\" FROM \"yap2\" WHERE \"extension\" = ? AND \"key\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)yapSetDataForKeyStatement
{
	sqlite3_stmt **statement = &yapSetDataForKeyStatement;
	if (*statement == NULL)
	{
		char *stmt = "INSERT OR REPLACE INTO \"yap2\" (\"extension\", \"key\", \"data\") VALUES (?, ?, ?);";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)yapRemoveForKeyStatement
{
	sqlite3_stmt **statement = &yapRemoveForKeyStatement;
	if (*statement == NULL)
	{
		char *stmt = "DELETE FROM \"yap2\" WHERE \"extension\" = ? AND \"key\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)yapRemoveExtensionStatement
{
	sqlite3_stmt **statement = &yapRemoveExtensionStatement;
	if (*statement == NULL)
	{
		char *stmt = "DELETE FROM \"yap2\" WHERE \"extension\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getCollectionCountStatement
{
	sqlite3_stmt **statement = &getCollectionCountStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT COUNT(DISTINCT collection) AS NumberOfRows FROM \"database2\";";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getKeyCountForCollectionStatement
{
	sqlite3_stmt **statement = &getKeyCountForCollectionStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT COUNT(*) AS NumberOfRows FROM \"database2\" WHERE \"collection\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getKeyCountForAllStatement
{
	sqlite3_stmt **statement = &getKeyCountForAllStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT COUNT(*) AS NumberOfRows FROM \"database2\";";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getCountForRowidStatement
{
	sqlite3_stmt **statement = &getCountForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT COUNT(*) AS NumberOfRows FROM \"database2\" WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getRowidForKeyStatement
{
	sqlite3_stmt **statement = &getRowidForKeyStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"rowid\" FROM \"database2\" WHERE \"collection\" = ? AND \"key\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getKeyForRowidStatement
{
	sqlite3_stmt **statement = &getKeyForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"collection\", \"key\" FROM \"database2\" WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getDataForRowidStatement
{
	sqlite3_stmt **statement = &getDataForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"data\" FROM \"database2\" WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getMetadataForRowidStatement
{
	sqlite3_stmt **statement = &getMetadataForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"metadata\" FROM \"database2\" WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getAllForRowidStatement
{
	sqlite3_stmt **statement = &getAllForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"data\", \"metadata\" FROM \"database2\" WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getDataForKeyStatement
{
	sqlite3_stmt **statement = &getDataForKeyStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"data\" FROM \"database2\" WHERE \"collection\" = ? AND \"key\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getMetadataForKeyStatement
{
	sqlite3_stmt **statement = &getMetadataForKeyStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"metadata\" FROM \"database2\" WHERE \"collection\" = ? AND \"key\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)getAllForKeyStatement
{
	sqlite3_stmt **statement = &getAllForKeyStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"data\", \"metadata\" FROM \"database2\" WHERE \"collection\" = ? AND \"key\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)insertForRowidStatement
{
	sqlite3_stmt **statement = &insertForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "INSERT INTO \"database2\""
		             " (\"collection\", \"key\", \"data\", \"metadata\") VALUES (?, ?, ?, ?);";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)updateAllForRowidStatement
{
	sqlite3_stmt **statement = &updateAllForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "UPDATE \"database2\" SET \"data\" = ?, \"metadata\" = ? WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)updateObjectForRowidStatement
{
	sqlite3_stmt **statement = &updateObjectForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "UPDATE \"database2\" SET \"data\" = ? WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)updateMetadataForRowidStatement
{
	sqlite3_stmt **statement = &updateMetadataForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "UPDATE \"database2\" SET \"metadata\" = ? WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)removeForRowidStatement
{
	sqlite3_stmt **statement = &removeForRowidStatement;
	if (*statement == NULL)
	{
		char *stmt = "DELETE FROM \"database2\" WHERE \"rowid\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)removeCollectionStatement
{
	sqlite3_stmt **statement = &removeCollectionStatement;
	if (*statement == NULL)
	{
		char *stmt = "DELETE FROM \"database2\" WHERE \"collection\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)removeAllStatement
{
	sqlite3_stmt **statement = &removeAllStatement;
	if (*statement == NULL)
	{
		char *stmt = "DELETE FROM \"database2\";";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateCollectionsStatement
{
	sqlite3_stmt **statement = &enumerateCollectionsStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT DISTINCT \"collection\" FROM \"database2\";";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateCollectionsForKeyStatement
{
	sqlite3_stmt **statement = &enumerateCollectionsForKeyStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"collection\" FROM \"database2\" WHERE \"key\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateKeysInCollectionStatement
{
	sqlite3_stmt **statement = &enumerateKeysInCollectionStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"key\" FROM \"database2\" WHERE collection = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateKeysInAllCollectionsStatement
{
	sqlite3_stmt **statement = &enumerateKeysInAllCollectionsStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"collection\", \"key\" FROM \"database2\";";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateKeysAndMetadataInCollectionStatement
{
	sqlite3_stmt **statement = &enumerateKeysAndMetadataInCollectionStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"key\", \"metadata\" FROM \"database2\" WHERE collection = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateKeysAndMetadataInAllCollectionsStatement
{
	sqlite3_stmt **statement = &enumerateKeysAndMetadataInAllCollectionsStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"collection\", \"key\", \"metadata\""
		             " FROM \"database2\" ORDER BY \"collection\" ASC;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateKeysAndObjectsInCollectionStatement
{
	sqlite3_stmt **statement = &enumerateKeysAndObjectsInCollectionStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"key\", \"data\" FROM \"database2\" WHERE \"collection\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateKeysAndObjectsInAllCollectionsStatement
{
	sqlite3_stmt **statement = &enumerateKeysAndObjectsInAllCollectionsStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"collection\", \"key\", \"data\""
		             " FROM \"database2\" ORDER BY \"collection\" ASC;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateRowsInCollectionStatement
{
	sqlite3_stmt **statement = &enumerateRowsInCollectionStatement;
	if (*statement == NULL)
	{
		char *stmt = "SELECT \"rowid\", \"key\", \"data\", \"metadata\" FROM \"database2\" WHERE \"collection\" = ?;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

- (sqlite3_stmt *)enumerateRowsInAllCollectionsStatement
{
	sqlite3_stmt **statement = &enumerateRowsInAllCollectionsStatement;
	if (*statement == NULL)
	{
		char *stmt =
		    "SELECT \"rowid\", \"collection\", \"key\", \"data\", \"metadata\""
		    " FROM \"database2\" ORDER BY \"collection\" ASC;";
		int stmtLen = (int)strlen(stmt);
		
		int status = sqlite3_prepare_v2(db, stmt, stmtLen+1, statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating '%@': %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		}
	}
	
	return *statement;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Transactions
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Read-only access to the database.
 *
 * The given block can run concurrently with sibling connections,
 * regardless of whether the sibling connections are executing read-only or read-write transactions.
 *
 * The only time this method ever blocks is if another thread is currently using this connection instance
 * to execute a readBlock or readWriteBlock. Recall that you may create multiple connections for concurrent access.
 *
 * This method is synchronous.
**/
- (void)readWithBlock:(void (^)(YapDatabaseReadTransaction *))block
{
#if YapDatabaseEnforcePermittedTransactions
	YapDatabasePermittedTransactions flags = self.permittedTransactions;
	if ((flags & YDB_MainThreadOnly) && !YDBIsMainThread())
	{
		@throw [self nonMainThreadException];
	}
	if (!(flags & YDB_SyncReadTransaction))
	{
		@throw [self unpermittedTransactionException:YDB_SyncReadTransaction];
	}
#endif
	
	dispatch_sync(connectionQueue, ^{ @autoreleasepool {
		
		if (longLivedReadTransaction)
		{
			block(longLivedReadTransaction);
		}
		else
		{
			YapDatabaseReadTransaction *transaction = [self newReadTransaction];
		
			[self preReadTransaction:transaction];
			block(transaction);
			[self postReadTransaction:transaction];
		}
	}});
}

/**
 * Read-write access to the database.
 * 
 * Only a single read-write block can execute among all sibling connections.
 * Thus this method may block if another sibling connection is currently executing a read-write block.
 * 
 * This method is synchronous.
**/
- (void)readWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
{
#if YapDatabaseEnforcePermittedTransactions
	YapDatabasePermittedTransactions flags = self.permittedTransactions;
	if ((flags & YDB_MainThreadOnly) && !YDBIsMainThread())
	{
		@throw [self nonMainThreadException];
	}
	if (!(flags & YDB_SyncReadWriteTransaction))
	{
		@throw [self unpermittedTransactionException:YDB_SyncReadWriteTransaction];
	}
#endif
	
	// Order matters.
	// First go through the serial connection queue.
	// Then go through serial write queue for the database.
	//
	// Once we're inside the database writeQueue, we know that we are the only write transaction.
	// No other transaction can possibly modify the database except us, even in other connections.
	
	dispatch_sync(connectionQueue, ^{
		
		if (longLivedReadTransaction)
		{
			if (throwExceptionsForImplicitlyEndingLongLivedReadTransaction)
			{
				@throw [self implicitlyEndingLongLivedReadTransactionException];
			}
			else
			{
				YDBLogWarn(@"Implicitly ending long-lived read transaction on connection %@, database %@",
				           self, database);
				
				[self endLongLivedReadTransaction];
			}
		}
		
		__preWriteQueue(self);
		dispatch_sync(database->writeQueue, ^{ @autoreleasepool {
			
			YapDatabaseReadWriteTransaction *transaction = [self newReadWriteTransaction];
			
			[self preReadWriteTransaction:transaction];
			block(transaction);
			[self postReadWriteTransaction:transaction];
			
		}}); // End dispatch_sync(database->writeQueue)
		__postWriteQueue(self);
	});      // End dispatch_sync(connectionQueue)
}

/**
 * Read-only access to the database.
 *
 * The given block can run concurrently with sibling connections,
 * regardless of whether the sibling connections are executing read-only or read-write transactions.
 *
 * This method is asynchronous.
**/
- (void)asyncReadWithBlock:(void (^)(YapDatabaseReadTransaction *transaction))block
{
	[self asyncReadWithBlock:block completionQueue:NULL completionBlock:NULL];
}

/**
 * Read-write access to the database.
 *
 * The given block can run concurrently with sibling connections,
 * regardless of whether the sibling connections are executing read-only or read-write transactions.
 *
 * This method is asynchronous.
 * 
 * An optional completion block may be used.
 * The completionBlock will be invoked on the main thread (dispatch_get_main_queue()).
**/
- (void)asyncReadWithBlock:(void (^)(YapDatabaseReadTransaction *transaction))block
           completionBlock:(dispatch_block_t)completionBlock
{
	[self asyncReadWithBlock:block completionQueue:NULL completionBlock:completionBlock];
}

/**
 * Read-write access to the database.
 *
 * The given block can run concurrently with sibling connections,
 * regardless of whether the sibling connections are executing read-only or read-write transactions.
 *
 * This method is asynchronous.
 * 
 * An optional completion block may be used.
 * Additionally the dispatch_queue to invoke the completion block may also be specified.
 * If NULL, dispatch_get_main_queue() is automatically used.
**/
- (void)asyncReadWithBlock:(void (^)(YapDatabaseReadTransaction *transaction))block
           completionQueue:(dispatch_queue_t)completionQueue
           completionBlock:(dispatch_block_t)completionBlock
{
#if YapDatabaseEnforcePermittedTransactions
	YapDatabasePermittedTransactions flags = self.permittedTransactions;
	if ((flags & YDB_MainThreadOnly) && !YDBIsMainThread())
	{
		@throw [self nonMainThreadException];
	}
	if (!(flags & YDB_AsyncReadTransaction))
	{
		@throw [self unpermittedTransactionException:YDB_AsyncReadTransaction];
	}
#endif
	
	if (completionQueue == NULL && completionBlock != NULL)
		completionQueue = dispatch_get_main_queue();
	
	dispatch_async(connectionQueue, ^{ @autoreleasepool {
		
		if (longLivedReadTransaction)
		{
			block(longLivedReadTransaction);
		}
		else
		{
			YapDatabaseReadTransaction *transaction = [self newReadTransaction];
			
			[self preReadTransaction:transaction];
			block(transaction);
			[self postReadTransaction:transaction];
		}
		
		if (completionBlock)
			dispatch_async(completionQueue, completionBlock);
	}});
}

/**
 * DEPRECATED in v2.5
 *
 * The syntax has been changed in order to make the code easier to read.
 * In the past the code would end up looking like this:
 *
 * [databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction){
 *     // 100 lines of code here
 * } completionBlock:^{
 *     // 50 lines of code here
 * }
 * completionQueue:importantQueue]; <-- Very hidden in code. Often overlooked.
 *
 * The new syntax puts the completionQueue declaration before the completionBlock declaration.
 * Since the two are intricately linked, they should be next to each other in code.
 * Then end result is much easier to read:
 *
 * [databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction){
 *     // 100 lines of code here
 * }
 * completionQueue:importantQueue <-- Easier to see
 * completionBlock:^{
 *     // 50 lines of code here
 * }];
**/
- (void)asyncReadWithBlock:(void (^)(YapDatabaseReadTransaction *transaction))block
           completionBlock:(dispatch_block_t)completionBlock
           completionQueue:(dispatch_queue_t)completionQueue
{
	[self asyncReadWithBlock:block completionQueue:completionQueue completionBlock:completionBlock];
}

/**
 * Read-write access to the database.
 * 
 * Only a single read-write block can execute among all sibling connections.
 * Thus this method may block if another sibling connection is currently executing a read-write block.
 * 
 * This method is asynchronous.
**/
- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
{
	[self asyncReadWriteWithBlock:block completionQueue:NULL completionBlock:NULL];
}

/**
 * Read-write access to the database.
 *
 * Only a single read-write block can execute among all sibling connections.
 * Thus the execution of the block may be delayted if another sibling connection
 * is currently executing a read-write block.
 *
 * This method is asynchronous.
 * 
 * An optional completion block may be used.
 * The completionBlock will be invoked on the main thread (dispatch_get_main_queue()).
**/
- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
                completionBlock:(dispatch_block_t)completionBlock
{
	[self asyncReadWriteWithBlock:block completionQueue:NULL completionBlock:completionBlock];
}

/**
 * Read-write access to the database.
 *
 * Only a single read-write block can execute among all sibling connections.
 * Thus the execution of the block may be delayted if another sibling connection
 * is currently executing a read-write block.
 *
 * This method is asynchronous.
 * 
 * An optional completion block may be used.
 * Additionally the dispatch_queue to invoke the completion block may also be specified.
 * If NULL, dispatch_get_main_queue() is automatically used.
**/
- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
                completionQueue:(dispatch_queue_t)completionQueue
                completionBlock:(dispatch_block_t)completionBlock
{
#if YapDatabaseEnforcePermittedTransactions
	YapDatabasePermittedTransactions flags = self.permittedTransactions;
	if ((flags & YDB_MainThreadOnly) && !YDBIsMainThread())
	{
		@throw [self nonMainThreadException];
	}
	if (!(flags & YDB_AsyncReadWriteTransaction))
	{
		@throw [self unpermittedTransactionException:YDB_AsyncReadWriteTransaction];
	}
#endif
	
	if (completionQueue == NULL && completionBlock != NULL)
		completionQueue = dispatch_get_main_queue();
	
	// Order matters.
	// First go through the serial connection queue.
	// Then go through serial write queue for the database.
	//
	// Once we're inside the database writeQueue, we know that we are the only write transaction.
	// No other transaction can possibly modify the database except us, even in other connections.
	
	dispatch_async(connectionQueue, ^{
		
		if (longLivedReadTransaction)
		{
			if (throwExceptionsForImplicitlyEndingLongLivedReadTransaction)
			{
				@throw [self implicitlyEndingLongLivedReadTransactionException];
			}
			else
			{
				YDBLogWarn(@"Implicitly ending long-lived read transaction on connection %@, database %@",
				           self, database);
				
				[self endLongLivedReadTransaction];
			}
		}
		
		__preWriteQueue(self);
		dispatch_sync(database->writeQueue, ^{ @autoreleasepool {
			
			YapDatabaseReadWriteTransaction *transaction = [self newReadWriteTransaction];
			
			[self preReadWriteTransaction:transaction];
			block(transaction);
			[self postReadWriteTransaction:transaction];
			
			if (completionBlock)
				dispatch_async(completionQueue, completionBlock);
			
		}}); // End dispatch_sync(database->writeQueue)
		__postWriteQueue(self);
	});      // End dispatch_async(connectionQueue)
}

/**
 * DEPRECATED in v2.5
 *
 * The syntax has been changed in order to make the code easier to read.
 * In the past the code would end up looking like this:
 *
 * [databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction){
 *     // 100 lines of code here
 * } completionBlock:^{
 *     // 50 lines of code here
 * }
 * completionQueue:importantQueue]; <-- Very hidden in code. Often overlooked.
 *
 * The new syntax puts the completionQueue declaration before the completionBlock declaration.
 * Since the two are intricately linked, they should be next to each other in code.
 * Then end result is much easier to read:
 *
 * [databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction){
 *     // 100 lines of code here
 * }
 * completionQueue:importantQueue <-- Easier to see
 * completionBlock:^{
 *     // 50 lines of code here
 * }];
**/
- (void)asyncReadWriteWithBlock:(void (^)(YapDatabaseReadWriteTransaction *transaction))block
                completionBlock:(dispatch_block_t)completionBlock
                completionQueue:(dispatch_queue_t)completionQueue
{
	[self asyncReadWriteWithBlock:block completionQueue:completionQueue completionBlock:completionBlock];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Transaction States
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required method.
 * Returns the proper type of transaction for this connection class.
**/
- (YapDatabaseReadTransaction *)newReadTransaction
{
	return [[YapDatabaseReadTransaction alloc] initWithConnection:self isReadWriteTransaction:NO];
}

/**
 * Required method.
 * Returns the proper type of transaction for this connection class.
**/
- (YapDatabaseReadWriteTransaction *)newReadWriteTransaction
{
	return [[YapDatabaseReadWriteTransaction alloc] initWithConnection:self isReadWriteTransaction:YES];
}

/**
 * This method executes the state transition steps required before executing a read-only transaction block.
 * 
 * This method must be invoked from within the connectionQueue.
**/
- (void)preReadTransaction:(YapDatabaseReadTransaction *)transaction
{
	// Pre-Read-Transaction: Step 1 of 3
	//
	// Execute "BEGIN TRANSACTION" on database connection.
	// This is actually a deferred transaction, meaning the sqlite connection won't actually
	// acquire a shared read lock until it executes a select statement.
	// There are alternatives to this, including a "begin immediate transaction".
	// However, this doesn't do what we want. Instead it blocks other read-only transactions.
	// The deferred transaction is actually what we want, as many read-only transactions only
	// hit our in-memory caches. Thus we avoid sqlite machinery when unneeded.
	
	[transaction beginTransaction];
		
	dispatch_sync(database->snapshotQueue, ^{ @autoreleasepool {
		
		// Pre-Read-Transaction: Step 2 of 3
		//
		// Update our connection state within the state table.
		//
		// First we need to mark this connection as being within a read-only transaction.
		// We do this by marking a "yap-level" shared read lock flag.
		//
		// Now recall from step 1 that our "sql-level" transaction is deferred.
		// The sql internals won't actually acquire the shared read lock until a we perform a select.
		// If there are write transactions in progress, this is a big problem for us.
		// Here's why:
		//
		// We have an in-memory snapshot via the caches.
		// This is kept in-sync with what's on disk (in the sqlite database file).
		// But what happens if the write transaction commits its changes before we perform our select statement?
		// Our select statement would acquire a different snapshot than our in-memory snapshot.
		// Thus, we look to see if there are any write transactions.
		// If there are, then we immediately acquire the "sql-level" shared read lock.
		
		BOOL hasActiveWriteTransaction = NO;
		YapDatabaseConnectionState *myState = nil;
		
		for (YapDatabaseConnectionState *state in database->connectionStates)
		{
			if (state->connection == self)
			{
				myState = state;
				myState->yapLevelSharedReadLock = YES;
			}
			else if (state->yapLevelExclusiveWriteLock)
			{
				hasActiveWriteTransaction = YES;
			}
		}
		
		NSAssert(myState != nil, @"Missing state in database->connectionStates");
		
		// Pre-Read-Transaction: Step 3 of 3
		//
		// Update our in-memory data (caches, etc) if needed.
		
		if (hasActiveWriteTransaction || longLivedReadTransaction)
		{
			// If this is for a longLivedReadTransaction,
			// then we need to immediately acquire a "sql-level" snapshot.
			//
			// Otherwise if there is a write transaction in progress,
			// then it's not safe to proceed until we acquire a "sql-level" snapshot.
			//
			// During this process we need to ensure that our "yap-level" snapshot of the in-memory data (caches, etc)
			// is in sync with our "sql-level" snapshot of the database.
			//
			// We can check this by comparing the connection's snapshot ivar with
			// the snapshot read from disk (via sqlite select).
			//
			// If the two match then our snapshots are in sync.
			// If they don't then we need to get caught up by processing changesets.
			
			uint64_t yapSnapshot = snapshot;
			uint64_t sqlSnapshot = [self readSnapshotFromDatabase];
			
			if (yapSnapshot < sqlSnapshot)
			{
				// The transaction can see the sqlite commit from another transaction,
				// and it hasn't processed the changeset(s) yet. We need to process them now.
				
				NSArray *changesets = [database pendingAndCommittedChangesSince:yapSnapshot until:sqlSnapshot];
				
				for (NSDictionary *changeset in changesets)
				{
					[self noteCommittedChanges:changeset];
				}
				
				NSAssert(snapshot == sqlSnapshot,
				         @"Invalid connection state in preReadTransaction: snapshot(%llu) != sqlSnapshot(%llu): %@",
				         snapshot, sqlSnapshot, changesets);
			}
			
			myState->lastKnownSnapshot = snapshot;
			myState->longLivedReadTransaction = (longLivedReadTransaction != nil);
			myState->sqlLevelSharedReadLock = YES;
			needsMarkSqlLevelSharedReadLock = NO;
		}
		else
		{
			// There is NOT a write transaction in progress.
			// Thus we are safe to proceed with only a "yap-level" snapshot.
			//
			// However, we MUST ensure that our "yap-level" snapshot of the in-memory data (caches, etc)
			// are in sync with the rest of the system.
			//
			// That is, our connection may have started its transaction before it was
			// able to process a changeset from a sibling connection.
			// If this is the case then we need to get caught up by processing the changeset(s).
			
			uint64_t localSnapshot = snapshot;
			uint64_t globalSnapshot = [database snapshot];
			
			if (localSnapshot < globalSnapshot)
			{
				// The transaction hasn't processed recent changeset(s) yet. We need to process them now.
				
				NSArray *changesets = [database pendingAndCommittedChangesSince:localSnapshot until:globalSnapshot];
				
				for (NSDictionary *changeset in changesets)
				{
					[self noteCommittedChanges:changeset];
				}
				
				NSAssert(snapshot == globalSnapshot,
				         @"Invalid connection state in preReadTransaction: snapshot(%llu) != globalSnapshot(%llu): %@",
				         snapshot, globalSnapshot, changesets);
			}
			
			myState->lastKnownSnapshot = snapshot;
			myState->sqlLevelSharedReadLock = NO;
			needsMarkSqlLevelSharedReadLock = YES;
		}
	}});
}

/**
 * This method executes the state transition steps required after executing a read-only transaction block.
 *
 * This method must be invoked from within the connectionQueue.
**/
- (void)postReadTransaction:(YapDatabaseReadTransaction *)transaction
{
	// Post-Read-Transaction: Step 1 of 4
	//
	// 1. Execute "COMMIT TRANSACTION" on database connection.
	// If we had acquired "sql-level" shared read lock, this will release associated resources.
	// It may also free the auto-checkpointing architecture within sqlite to sync the WAL to the database.
	
	[transaction commitTransaction];
	
	__block uint64_t minSnapshot = 0;
	__block YapDatabaseConnectionState *writeStateToSignal = nil;
	
	dispatch_sync(database->snapshotQueue, ^{ @autoreleasepool {
		
		// Post-Read-Transaction: Step 2 of 4
		//
		// Update our connection state within the state table.
		//
		// First we need to mark this connection as no longer being within a read-only transaction.
		// We do this by unmarking the "yap-level" and "sql-level" shared read lock flags.
		//
		// While we're doing this we also check to see if we were possibly blocking a write transaction.
		// When does a write transaction get blocked?
		//
		// Recall from the discussion above that we don't always acquire a "sql-level" shared read lock.
		// Our sql transaction is deferred until our first select statement.
		// Now if a write transaction comes along and discovers there are existing read transactions that
		// have an in-memory metadata snapshot, but haven't acquired an "sql-level" snapshot of the actual
		// database, it will block until these read transctions either complete,
		// or acquire the needed "sql-level" snapshot.
		//
		// So if we never acquired an "sql-level" snapshot of the database, and we were the last transaction
		// in such a state, and there's a blocked write transaction, then we need to signal it.
		
		minSnapshot = [database snapshot];
		
		BOOL wasMaybeBlockingWriteTransaction = NO;
		NSUInteger countOtherMaybeBlockingWriteTransaction = 0;
		YapDatabaseConnectionState *blockedWriteState = nil;
		
		for (YapDatabaseConnectionState *state in database->connectionStates)
		{
			if (state->connection == self)
			{
				wasMaybeBlockingWriteTransaction = state->yapLevelSharedReadLock && !state->sqlLevelSharedReadLock;
				state->yapLevelSharedReadLock = NO;
				state->sqlLevelSharedReadLock = NO;
				state->longLivedReadTransaction = NO;
			}
			else if (state->yapLevelSharedReadLock)
			{
				// Active sibling connection: read-only
				
				minSnapshot = MIN(state->lastKnownSnapshot, minSnapshot);
				
				if (!state->sqlLevelSharedReadLock)
					countOtherMaybeBlockingWriteTransaction++;
			}
			else if (state->yapLevelExclusiveWriteLock)
			{
				// Active sibling connection: read-write
				
				minSnapshot = MIN(state->lastKnownSnapshot, minSnapshot);
				
				if (state->waitingForWriteLock)
					blockedWriteState = state;
			}
		}
		
		if (wasMaybeBlockingWriteTransaction && countOtherMaybeBlockingWriteTransaction == 0 && blockedWriteState)
		{
			writeStateToSignal = blockedWriteState;
		}
		
		YDBLogVerbose(@"YapDatabaseConnection(%p) completing read-only transaction.", self);
	}});
	
	// Post-Read-Transaction: Step 3 of 4
	//
	// Check to see if this connection has been holding back the checkpoint process.
	// That is, was this connection the last active connection on an old snapshot?
	
	if (snapshot < minSnapshot)
	{
		// There are commits ahead of us that need to be checkpointed.
		// And we were the oldest active connection,
		// so we were previously preventing the checkpoint from progressing.
		// Thus we can now continue the checkpoint operation.
		
		[database asyncCheckpoint:minSnapshot];
		
		[registeredMemoryTables enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
			
			[(YapMemoryTable *)obj asyncCheckpoint:minSnapshot];
		}];
	}
	
	// Post-Read-Transaction: Step 4 of 4
	//
	// If we discovered a blocked write transaction,
	// and it was blocked waiting on us (because we had a "yap-level" snapshot without an "sql-level" snapshot),
	// and it's no longer blocked on any other read transaction (that have "yap-level" snapshots
	// without "sql-level snapshots"), then signal the write semaphore so the blocked thread wakes up.
	
	if (writeStateToSignal)
	{
		YDBLogVerbose(@"YapDatabaseConnection(%p) signaling blocked write on connection(%p)",
		                                    self, writeStateToSignal->connection);
		
		[writeStateToSignal signalWriteLock];
	}
}

/**
 * This method executes the state transition steps required before executing a read-write transaction block.
 * 
 * This method must be invoked from within the connectionQueue.
 * This method must be invoked from within the database.writeQueue.
**/
- (void)preReadWriteTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
	// Pre-Write-Transaction: Step 1 of 5
	//
	// Execute "BEGIN TRANSACTION" on database connection.
	// This is actually a deferred transaction, meaning the sqlite connection won't actually
	// acquire any locks until it executes something.
	// There are various alternatives to this, including a "immediate" and "exclusive" transactions.
	// However, these don't do what we want. Instead they block other read-only transactions.
	// The deferred transaction allows other read-only transactions and even avoids
	// sqlite operations if no modifications are made.
	//
	// Remember, we are the only active write transaction for this database.
	// No other write transactions can occur until this transaction completes.
	// Thus no other transactions can possibly modify the database during our transaction.
	// Therefore it doesn't matter when we acquire our "sql-level" locks for writing.
	
	[transaction beginTransaction];
	
	dispatch_sync(database->snapshotQueue, ^{ @autoreleasepool {
		
		// Pre-Write-Transaction: Step 2 of 5
		//
		// Update our connection state within the state table.
		//
		// We are the only write transaction for this database.
		// It is important for read-only transactions on other connections to know there's a writer.
		
		YapDatabaseConnectionState *myState = nil;
		
		for (YapDatabaseConnectionState *state in database->connectionStates)
		{
			if (state->connection == self)
			{
				myState = state;
				myState->yapLevelExclusiveWriteLock = YES;
			}
		}
		
		NSAssert(myState != nil, @"Missing state in database->connectionStates");
		
		// Pre-Write-Transaction: Step 3 of 5
		//
		// Validate our caches based on snapshot numbers
		
		uint64_t localSnapshot = snapshot;
		uint64_t globalSnapshot = [database snapshot];
		
		if (localSnapshot < globalSnapshot)
		{
			NSArray *changesets = [database pendingAndCommittedChangesSince:localSnapshot until:globalSnapshot];
			
			for (NSDictionary *changeset in changesets)
			{
				[self noteCommittedChanges:changeset];
			}
			
			NSAssert(snapshot == globalSnapshot,
			         @"Invalid connection state in preReadWriteTransaction: snapshot(%llu) != globalSnapshot(%llu)",
			         snapshot, globalSnapshot);
		}
		
		myState->lastKnownSnapshot = snapshot;
		needsMarkSqlLevelSharedReadLock = NO;
		
		YDBLogVerbose(@"YapDatabaseConnection(%p) starting read-write transaction.", self);
	}});
	
	// Pre-Write-Transaction: Step 4 of 5
	//
	// Setup write state and changeset variables
	
	hasDiskChanges = NO;
	
	if (objectChanges == nil)
		objectChanges = [[NSMutableDictionary alloc] init];
	
	if (metadataChanges == nil)
		metadataChanges = [[NSMutableDictionary alloc] init];
	
	if (removedKeys == nil)
		removedKeys = [[NSMutableSet alloc] init];
	
	if (removedCollections == nil)
		removedCollections = [[NSMutableSet alloc] init];
	
	if (removedRowids == nil)
		removedRowids = [[NSMutableSet alloc] init];
	
	allKeysRemoved = NO;
	
	// Pre-Write-Transaction: Step 5 of 5
	//
	// Add IsOnConnectionQueueKey flag to writeQueue.
	// This allows various methods that depend on the flag to operate correctly.
	
	dispatch_queue_set_specific(database->writeQueue, IsOnConnectionQueueKey, IsOnConnectionQueueKey, NULL);
}

/**
 * This method executes the state transition steps required after executing a read-only transaction block.
 *
 * This method must be invoked from within the connectionQueue.
 * This method must be invoked from within the database.writeQueue.
**/
- (void)postReadWriteTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
	if (transaction->rollback)
	{
		// Rollback-Write-Transaction: Step 1 of 2
		//
		// Update our connection state within the state table.
		//
		// We are the only write transaction for this database.
		// It is important for read-only transactions on other connections to know we're no longer a writer.
		
		dispatch_sync(database->snapshotQueue, ^{
		
			for (YapDatabaseConnectionState *state in database->connectionStates)
			{
				if (state->connection == self)
				{
					state->yapLevelExclusiveWriteLock = NO;
					break;
				}
			}
		});
		
		// Rollback-Write-Transaction: Step 2 of 3
		//
		// Rollback sqlite database transaction.
		
		[transaction rollbackTransaction];
		
		// Rollback-Write-Transaction: Step 3 of 3
		//
		// Reset any in-memory variables which may be out-of-sync with the database.
		
		[self postRollbackCleanup];
		
		YDBLogVerbose(@"YapDatabaseConnection(%p) completing read-write transaction (rollback).", self);
		
		return;
	}
	
	// Post-Write-Transaction: Step 1 of 11
	//
	// Run any pre-commit operations.
	// This allows extensions to to perform any cleanup before the changeset is requested.
	
	[transaction preCommitReadWriteTransaction];
	
	// Post-Write-Transaction: Step 2 of 11
	//
	// Fetch changesets.
	// Then update the snapshot in the 'yap' database (if any changes were made).
	// We use 'yap' database and snapshot value to check for a race condition.
	//
	// The "internal" changeset gets sent directly to sibling database connections.
	// The "external" changeset gets plugged into the YapDatabaseModifiedNotification as the userInfo dict.
	
	NSNotification *notification = nil;
	
	NSMutableDictionary *changeset = nil;
	NSMutableDictionary *userInfo = nil;
	
	[self getInternalChangeset:&changeset externalChangeset:&userInfo];
	if (changeset || userInfo || hasDiskChanges)
	{
		// If hasDiskChanges is YES, then the database file was modified.
		// In this case, we're sure to write the incremented snapshot number to the database.
		//
		// If hasDiskChanges is NO, then the database file was not modified.
		// However, something was "touched" or an in-memory extension was changed.
		
		if (hasDiskChanges)
			snapshot = [self incrementSnapshotInDatabase];
		else
			snapshot++;
		
		if (changeset == nil)
			changeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForInternalChangeset];
		
		if (userInfo == nil)
			userInfo = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForExternalChangeset];
		
		[changeset setObject:@(snapshot) forKey:YapDatabaseSnapshotKey];
		[userInfo setObject:@(snapshot) forKey:YapDatabaseSnapshotKey];
		
		[userInfo setObject:self forKey:YapDatabaseConnectionKey];
		
		if (transaction->customObjectForNotification)
			[userInfo setObject:transaction->customObjectForNotification forKey:YapDatabaseCustomKey];
		
		notification = [NSNotification notificationWithName:YapDatabaseModifiedNotification
		                                             object:database
		                                           userInfo:userInfo];
		
		[changeset setObject:notification forKey:YapDatabaseNotificationKey];
	}
	
	// Post-Write-Transaction: Step 3 of 11
	//
	// Auto-drop tables from previous extensions that aren't being used anymore.
	//
	// Note the timing of when this happens:
	// - Only once
	// - At the end of a readwrite transaction that has made modifications to the database
	// - Only if the modifications weren't dedicated to registering/unregistring an extension
	
	if (database->previouslyRegisteredExtensionNames && changeset && !registeredExtensionsChanged)
	{
		for (NSString *prevExtensionName in database->previouslyRegisteredExtensionNames)
		{
			if ([registeredExtensions objectForKey:prevExtensionName] == nil)
			{
				[self _unregisterExtensionWithName:prevExtensionName transaction:transaction];
			}
		}
		
		database->previouslyRegisteredExtensionNames = nil;
	}
	
	// Post-Write-Transaction: Step 4 of 11
	//
	// Check to see if it's safe to commit our changes.
	//
	// There may be read-only transactions that have acquired "yap-level" snapshots
	// without "sql-level" snapshots. That is, these read-only transaction may have a snapshot
	// of the in-memory metadata dictionary at the time they started, but as for the sqlite connection
	// they only have a "BEGIN DEFERRED TRANSACTION", and haven't actually executed
	// any "select" statements. Thus they haven't actually invoked the sqlite machinery to
	// acquire the "sql-level" snapshot (last valid commit record in the WAL).
	//
	// It is our responsibility to block until all read-only transactions have either completed,
	// or have acquired the necessary "sql-level" shared read lock.
	//
	// We avoid writer starvation by enforcing new read-only transactions that start after our writer
	// started to immediately acquire "sql-level" shared read locks when they start.
	// Thus we would only ever wait for read-only transactions that started before our
	// read-write transaction started. And since most of the time the read-write transactions
	// take longer than read-only transactions, we avoid any blocking in most cases.
	
	__block YapDatabaseConnectionState *myState = nil;
	__block BOOL safeToCommit = NO;
	
	do
	{
		__block BOOL waitForReadOnlyTransactions = NO;
		
		dispatch_sync(database->snapshotQueue, ^{ @autoreleasepool {
			
			for (YapDatabaseConnectionState *state in database->connectionStates)
			{
				if (state->connection == self)
				{
					myState = state;
				}
				else if (state->yapLevelSharedReadLock && !state->sqlLevelSharedReadLock)
				{
					waitForReadOnlyTransactions = YES;
				}
			}
			
			NSAssert(myState != nil, @"Missing state in database->connectionStates");
			
			if (waitForReadOnlyTransactions)
			{
				myState->waitingForWriteLock = YES;
				[myState prepareWriteLock];
			}
			else
			{
				myState->waitingForWriteLock = NO;
				safeToCommit = YES;
				
				// Post-Write-Transaction: Step 5 of 11
				//
				// Register pending changeset with database.
				// Our commit is actually a two step process.
				// First we execute the sqlite level commit.
				// Second we execute the final stages of the yap level commit.
				//
				// This two step process means we have an edge case,
				// where another connection could come around and begin its yap level transaction
				// before this connections yap level commit, but after this connections sqlite level commit.
				//
				// By registering the pending changeset in advance,
				// we provide a near seamless workaround for the edge case.
				
				if (changeset)
				{
					[database notePendingChanges:changeset fromConnection:self];
				}
			}
			
		}});
		
		if (waitForReadOnlyTransactions)
		{
			// Block until a read-only transaction signals us.
			// This will occur when the last read-only transaction (that started before our read-write
			// transaction started) either completes or acquires an "sql-level" shared read lock.
			//
			// Note: Since we're using a dispatch semaphore, order doesn't matter.
			// That is, it's fine if the read-only transaction signals our write lock before we start waiting on it.
			// In this case we simply return immediately from the wait call.
			
			YDBLogVerbose(@"YapDatabaseConnection(%p) blocked waiting for write lock...", self);
			
			[myState waitForWriteLock];
		}
		
	} while (!safeToCommit);
	
	// Post-Write-Transaction: Step 6 of 11
	//
	// Execute "COMMIT TRANSACTION" on database connection.
	// This will write the changes to the WAL, and may invoke a checkpoint.
	//
	// Notice that we do this outside the context of the transactionStateQueue.
	// We do this so we don't block read-only transactions from starting or finishing.
	// However, this does leave us open for the possibility that a read-only transaction will
	// get a "yap-level" snapshot of the metadata dictionary before this commit,
	// but a "sql-level" snapshot of the sql database after this commit.
	// This is rare but must be guarded against.
	// The solution is pretty simple and straight-forward.
	// When a read-only transaction starts, if there's an active write transaction,
	// it immediately acquires an "sql-level" snapshot. It does this by invoking a select statement,
	// which invokes the internal sqlite snapshot machinery for the transaction.
	// So rather than using a dummy select statement that we ignore, we instead select a lastCommit number
	// from the database. If it doesn't match what we expect, then we know we've run into the race condition,
	// and we make the read-only transaction back out and try again.
	
	[transaction commitTransaction];
	
	__block uint64_t minSnapshot = UINT64_MAX;
	
	dispatch_sync(database->snapshotQueue, ^{ @autoreleasepool {
		
		// Post-Write-Transaction: Step 7 of 11
		//
		// Notify database of changes, and drop reference to set of changed keys.
		
		if (changeset)
		{
			[database noteCommittedChanges:changeset fromConnection:self];
		}
		
		// Post-Write-Transaction: Step 8 of 11
		//
		// Update our connection state within the state table.
		//
		// We are the only write transaction for this database.
		// It is important for read-only transactions on other connections to know we're no longer a writer.
		
		for (YapDatabaseConnectionState *state in database->connectionStates)
		{
			if (state->yapLevelSharedReadLock)
			{
				minSnapshot = MIN(state->lastKnownSnapshot, minSnapshot);
			}
		}
		
		myState->yapLevelExclusiveWriteLock = NO;
		myState->waitingForWriteLock = NO;
		
		YDBLogVerbose(@"YapDatabaseConnection(%p) completing read-write transaction.", self);
	}});
	
	// Post-Write-Transaction: Step 9 of 11
	
	if (changeset)
	{
		// We added frames to the WAL.
		// We can invoke a checkpoint if there are no other active connections.
		
		if (minSnapshot == UINT64_MAX)
		{
			[database asyncCheckpoint:snapshot];
			
			[registeredMemoryTables enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
				
				[(YapMemoryTable *)obj asyncCheckpoint:snapshot];
			}];
		}
	}
	
	// Post-Write-Transaction: Step 10 of 11
	//
	// Post YapDatabaseModifiedNotification (if needed),
	// and clear changeset variables (which are now a part of the notification).
	
	if (notification)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			[[NSNotificationCenter defaultCenter] postNotification:notification];
		});
	}
	
	if ([objectChanges count] > 0)
		objectChanges = nil;
	
	if ([metadataChanges count] > 0)
		metadataChanges = nil;
	
	if ([removedKeys count] > 0)
		removedKeys = nil;
	
	if ([removedCollections count] > 0)
		removedCollections = nil;
	
	if ([removedRowids count] > 0)
		removedRowids = nil;
	
	// Post-Write-Transaction: Step 11 of 11
	//
	// Drop IsOnConnectionQueueKey flag from writeQueue since we're exiting writeQueue.
	
	dispatch_queue_set_specific(database->writeQueue, IsOnConnectionQueueKey, NULL, NULL);
}

/**
 * This method executes the state transition steps required before executing a vacuum operation.
 *
 * This method must be invoked from within the connectionQueue.
 * This method must be invoked from within the database.writeQueue.
**/
- (void)preVacuum
{
	// A vacuum operation is similar to a read-write transaction,
	// in that it modifies the database, and so must block other writers (go through writeQueue).
	//
	// However, a vacuum operation cannot occur within a transaction.
	// So we cannot simply use preReadWriteTransaction & postReadWriteTransaction.
	// Instead we use a select subset of them.
	
	// Pre-Vacuum: Step 1 of 1
	//
	// Update our connection state within the state table.
	//
	// We are the only write transaction for this database.
	// It is important for read-only transactions on other connections to know there's a writer.
	
	dispatch_sync(database->snapshotQueue, ^{ @autoreleasepool {
		
		YapDatabaseConnectionState *myState = nil;
		
		for (YapDatabaseConnectionState *state in database->connectionStates)
		{
			if (state->connection == self)
			{
				myState = state;
				myState->yapLevelExclusiveWriteLock = YES;
			}
		}
		
		NSAssert(myState != nil, @"Missing state in database->connectionStates");
		
		myState->lastKnownSnapshot = [database snapshot];
		needsMarkSqlLevelSharedReadLock = YES;
		
		YDBLogVerbose(@"YapDatabaseConnection(%p) starting vacuum operation.", self);
	}});
}

/**
 * This method executes the state transition steps required after executing a vacuum operation.
 *
 * This method must be invoked from within the connectionQueue.
 * This method must be invoked from within the database.writeQueue.
**/
- (void)postVacuum
{
	// A vacuum operation is similar to a read-write transaction,
	// in that it modifies the database, and so must block other writers (go through writeQueue).
	//
	// However, a vacuum operation cannot occur within a transaction.
	// So we cannot simply use preReadWriteTransaction & postReadWriteTransaction.
	// Instead we use a select subset of them.
	
	// Post-Vacuum: Step 1 of 4
	//
	// Create changeset.
	// We're doing this in order to increment the snapshot.
	
	snapshot++;
	
	NSMutableDictionary *changeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForInternalChangeset];
	NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForExternalChangeset];
	
	[changeset setObject:@(snapshot) forKey:YapDatabaseSnapshotKey];
	[userInfo setObject:@(snapshot) forKey:YapDatabaseSnapshotKey];
	
	[userInfo setObject:self forKey:YapDatabaseConnectionKey];
		
	NSNotification *notification = [NSNotification notificationWithName:YapDatabaseModifiedNotification
	                                                             object:database
	                                                           userInfo:userInfo];
	
	[changeset setObject:notification forKey:YapDatabaseNotificationKey];
	
	__block YapDatabaseConnectionState *myState = nil;
	__block uint64_t minSnapshot = UINT64_MAX;
	
	dispatch_sync(database->snapshotQueue, ^{ @autoreleasepool {
		
		// Post-Write-Transaction: Step 2 of 4
		//
		// Notify database of changes, and drop reference to set of changed keys.
		
		[database notePendingChanges:changeset fromConnection:self];
		[database noteCommittedChanges:changeset fromConnection:self];
		
		// Post-Vacuum: Step 3 of 4
		//
		// Update our connection state within the state table.
		//
		// We are the only write transaction for this database.
		// It is important for read-only transactions on other connections to know we're no longer a writer.
		
		for (YapDatabaseConnectionState *state in database->connectionStates)
		{
			if (state->connection == self)
			{
				myState = state;
			}
			else if (state->yapLevelSharedReadLock)
			{
				minSnapshot = MIN(state->lastKnownSnapshot, minSnapshot);
			}
		}
		
		NSAssert(myState != nil, @"Missing state in database->connectionStates");
		
		myState->yapLevelExclusiveWriteLock = NO;
		myState->waitingForWriteLock = NO;
		
		YDBLogVerbose(@"YapDatabaseConnection(%p) completing read-write transaction.", self);
	}});
	
	// Post-Vacuum: Step 4 of 4
	//
	// We added frames to the WAL.
	// We can invoke a checkpoint if there are no other active connections.
	
	if (minSnapshot == UINT64_MAX)
	{
		[database asyncCheckpoint:snapshot];
		
		// Note: We didn't actually change anything in the database.
		// The vacuum operation just defragments the database file.
		//
		// So there's no need to do anything concerning registeredMemoryTables.
	}
}

/**
 * This method "kills two birds with one stone".
 * 
 * First, it invokes a SELECT statement on the database.
 * This executes the sqlite machinery to acquire a "sql-level" snapshot of the database.
 * That is, the encompassing transaction will now reference a specific commit record in the WAL,
 * and will ignore any commits made after this record.
 * 
 * Second, it reads a specific value from the database, and tells us which commit record in the WAL its using.
 * This allows us to validate the transaction, and check for a particular race condition.
**/
- (uint64_t)readSnapshotFromDatabase
{
	sqlite3_stmt *statement = [self yapGetDataForKeyStatement];
	if (statement == NULL) return 0;
	
	uint64_t result = 0;
	
	// SELECT data FROM 'yap2' WHERE extension = ? AND key = ? ;
	
	char *extension = "";
	sqlite3_bind_text(statement, 1, extension, (int)strlen(extension), SQLITE_STATIC);
	
	char *key = "snapshot";
	sqlite3_bind_text(statement, 2, key, (int)strlen(key), SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		result = (uint64_t)sqlite3_column_int64(statement, 0);
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'yapGetDataForKeyStatement': %d %s",
		                                                       status, sqlite3_errmsg(db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	
	return result;
}

/**
 * This method updates the 'snapshot' row in the database.
**/
- (uint64_t)incrementSnapshotInDatabase
{
	uint64_t newSnapshot = snapshot + 1;
	
	sqlite3_stmt *statement = [self yapSetDataForKeyStatement];
	if (statement == NULL) return newSnapshot;
	
	// INSERT OR REPLACE INTO "yap2" ("extension", "key", "data") VALUES (?, ?, ?);
	
	char *extension = "";
	sqlite3_bind_text(statement, 1, extension, (int)strlen(extension), SQLITE_STATIC);
	
	char *key = "snapshot";
	sqlite3_bind_text(statement, 2, key, (int)strlen(key), SQLITE_STATIC);
	
	sqlite3_bind_int64(statement, 3, (sqlite3_int64)newSnapshot);
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"Error executing 'yapSetDataForKeyStatement': %d %s",
		                                                       status, sqlite3_errmsg(db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	
	return newSnapshot;
}

- (void)markSqlLevelSharedReadLockAcquired
{
	NSAssert(needsMarkSqlLevelSharedReadLock, @"Method called but unneeded. Unnecessary overhead.");
	if (!needsMarkSqlLevelSharedReadLock) return;
	
	__block YapDatabaseConnectionState *writeStateToSignal = nil;
	
	dispatch_sync(database->snapshotQueue, ^{ @autoreleasepool {
		
		// Update our connection state within the state table.
		//
		// We need to mark this connection as having acquired an "sql-level" shared read lock.
		// That is, our sqlite connection has invoked a select statement, and has thus invoked the sqlite
		// machinery that causes it to acquire the "sql-level" snapshot (last valid commit record in the WAL).
		//
		// While we're doing this we also check to see if we were possibly blocking a write transaction.
		// When does a write transaction get blocked?
		//
		// If a write transaction goes to commit its changes and sees a read-only transaction with
		// a "yap-level" snapshot of the in-memory metadata snapshot, but without an "sql-level" snapshot
		// of the actual database, it will block until these read transctions either complete,
		// or acquire the needed "sql-level" snapshot.
		//
		// So if we never acquired an "sql-level" snapshot of the database, and we were the last transaction
		// in such a state, and there's a blocked write transaction, then we need to signal it.
		
		__block NSUInteger countOtherMaybeBlockingWriteTransaction = 0;
		__block YapDatabaseConnectionState *blockedWriteState = nil;
		
		for (YapDatabaseConnectionState *state in database->connectionStates)
		{
			if (state->connection == self)
			{
				state->sqlLevelSharedReadLock = YES;
			}
			else if (state->yapLevelSharedReadLock && !state->sqlLevelSharedReadLock)
			{
				countOtherMaybeBlockingWriteTransaction++;
			}
			else if (state->waitingForWriteLock)
			{
				blockedWriteState = state;
			}
		}
		
		if (countOtherMaybeBlockingWriteTransaction == 0 && blockedWriteState)
		{
			writeStateToSignal = blockedWriteState;
		}
	}});
	
	needsMarkSqlLevelSharedReadLock = NO;
	
	if (writeStateToSignal)
	{
		YDBLogVerbose(@"YapDatabaseConnection(%p) signaling blocked write on connection(%p)",
											 self, writeStateToSignal->connection);
		[writeStateToSignal signalWriteLock];
	}
}

/**
 * This method is invoked after a read-write transaction completes, which was rolled-back.
 * You should flush anything from memory that may be out-of-sync with the database.
**/
- (void)postRollbackCleanup
{
	[objectCache removeAllObjects];
	[metadataCache removeAllObjects];
	
	if ([objectChanges count] > 0)
		objectChanges = nil;
	
	if ([metadataChanges count] > 0)
		metadataChanges = nil;
	
	if ([removedKeys count] > 0)
		removedKeys = nil;
	
	if ([removedCollections count] > 0)
		removedCollections = nil;
	
	if ([removedRowids count] > 0)
		removedRowids = nil;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Long-Lived Transactions
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSArray *)beginLongLivedReadTransaction
{
	__block NSMutableArray *notifications = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		if (longLivedReadTransaction)
		{
			// Caller using implicit atomic reBeginLongLivedReadTransaction
			notifications = (NSMutableArray *)[self endLongLivedReadTransaction];
		}
		
		longLivedReadTransaction = [self newReadTransaction];
		[self preReadTransaction:longLivedReadTransaction];
		
		// The preReadTransaction method acquires the "sqlite-level" snapshot.
		// In doing so, if it needs to fetch and process any changesets,
		// then it adds them to the processedChangesets ivar for us.
		
		if (notifications == nil)
			notifications = [NSMutableArray arrayWithCapacity:[processedChangesets count]];
		
		for (NSDictionary *changeset in processedChangesets)
		{
			// The changeset has already been processed.
			
			NSNotification *notification = [changeset objectForKey:YapDatabaseNotificationKey];
			if (notification) {
				[notifications addObject:notification];
			}
		}
		
		[processedChangesets removeAllObjects];
	}};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return notifications;
}

- (NSArray *)endLongLivedReadTransaction
{
	__block NSMutableArray *notifications = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		if (longLivedReadTransaction)
		{
			// End the transaction (sqlite commit)
			
			[self postReadTransaction:longLivedReadTransaction];
			longLivedReadTransaction = nil;
			
			// Now process any changesets that were pending.
			// And extract the corresponding external notifications to return the the caller.
			
			notifications = [NSMutableArray arrayWithCapacity:[pendingChangesets count]];
			
			for (NSDictionary *changeset in pendingChangesets)
			{
				[self noteCommittedChanges:changeset];
				
				NSNotification *notification = [changeset objectForKey:YapDatabaseNotificationKey];
				if (notification) {
					[notifications addObject:notification];
				}
			}
			
			[pendingChangesets removeAllObjects];
		}
	}};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return notifications;
}

- (BOOL)isInLongLivedReadTransaction
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
		
		result = (longLivedReadTransaction != nil);
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return result;
}

- (void)enableExceptionsForImplicitlyEndingLongLivedReadTransaction
{
	dispatch_block_t block = ^{
		
		throwExceptionsForImplicitlyEndingLongLivedReadTransaction = YES;
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

- (void)disableExceptionsForImplicitlyEndingLongLivedReadTransaction
{
	dispatch_block_t block = ^{
		
		throwExceptionsForImplicitlyEndingLongLivedReadTransaction = NO;
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_async(connectionQueue, block);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Changeset Architecture
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The creation of changeset dictionaries happens constantly.
 * So, to optimize a bit, we use sharedKeySet's (part of NSDictionary).
 * 
 * See ivar 'sharedKeySetForInternalChangeset'
**/
- (NSArray *)internalChangesetKeys
{
	return @[ YapDatabaseSnapshotKey,
	          YapDatabaseExtensionsKey,
	          YapDatabaseRegisteredExtensionsKey,
	          YapDatabaseRegisteredMemoryTablesKey,
	          YapDatabaseExtensionsOrderKey,
	          YapDatabaseExtensionDependenciesKey,
	          YapDatabaseNotificationKey,
	          YapDatabaseObjectChangesKey,
	          YapDatabaseMetadataChangesKey,
	          YapDatabaseRemovedKeysKey,
	          YapDatabaseRemovedCollectionsKey,
	          YapDatabaseRemovedRowidsKey,
	          YapDatabaseAllKeysRemovedKey ];
}

/**
 * The creation of changeset dictionaries happens constantly.
 * So, to optimize a bit, we use sharedKeySet's (part of NSDictionary).
 *
 * See ivar 'sharedKeySetForExternalChangeset'
**/
- (NSArray *)externalChangesetKeys
{
	return @[ YapDatabaseSnapshotKey,
	          YapDatabaseConnectionKey,
	          YapDatabaseExtensionsKey,
	          YapDatabaseCustomKey,
	          YapDatabaseObjectChangesKey,
	          YapDatabaseMetadataChangesKey,
	          YapDatabaseRemovedKeysKey,
	          YapDatabaseRemovedCollectionsKey,
	          YapDatabaseAllKeysRemovedKey ];
}

/**
 * This method is invoked from within the postReadWriteTransaction operation.
 * This method is invoked before anything has been committed.
 *
 * If changes have been made, it should return a changeset dictionary.
 * If no changes have been made, it should return nil.
 * 
 * @see processChangeset:
**/
- (void)getInternalChangeset:(NSMutableDictionary **)internalChangesetPtr
           externalChangeset:(NSMutableDictionary **)externalChangesetPtr
{
	// Step 1 of 2 - Process extensions
	//
	// Note: Use existing extensions (extensions ivar, not [self extensions]).
	// There's no need to create any new extConnections at this point.
	
	__block NSMutableDictionary *internalChangeset_extensions = nil;
	__block NSMutableDictionary *externalChangeset_extensions = nil;
	
	[extensions enumerateKeysAndObjectsUsingBlock:^(id extName, id extConnectionObj, BOOL *stop) {
		
		__unsafe_unretained YapDatabaseExtensionConnection *extConnection = extConnectionObj;
		
		NSMutableDictionary *internal = nil;
		NSMutableDictionary *external = nil;
		BOOL extHasDiskChanges = NO;
		
		[extConnection getInternalChangeset:&internal
		                  externalChangeset:&external
		                     hasDiskChanges:&extHasDiskChanges];
		
		if (internal)
		{
			if (internalChangeset_extensions == nil)
				internalChangeset_extensions =
				    [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForExtensions];
			
			[internalChangeset_extensions setObject:internal forKey:extName];
		}
		if (external)
		{
			if (externalChangeset_extensions == nil)
				externalChangeset_extensions =
				    [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForExtensions];
			
			[externalChangeset_extensions setObject:external forKey:extName];
		}
		if (extHasDiskChanges && !hasDiskChanges)
		{
			hasDiskChanges = YES;
		}
	}];
	
	NSMutableDictionary *internalChangeset = nil;
	NSMutableDictionary *externalChangeset = nil;
	
	if (internalChangeset_extensions)
	{
		internalChangeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForInternalChangeset];
		[internalChangeset setObject:internalChangeset_extensions forKey:YapDatabaseExtensionsKey];
	}
	
	if (externalChangeset_extensions)
	{
		externalChangeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForExternalChangeset];
		[externalChangeset setObject:externalChangeset_extensions forKey:YapDatabaseExtensionsKey];
	}
	
	if (registeredExtensionsChanged)
	{
		if (internalChangeset == nil)
			internalChangeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForInternalChangeset];
		
		[internalChangeset setObject:registeredExtensions forKey:YapDatabaseRegisteredExtensionsKey];
		[internalChangeset setObject:extensionsOrder forKey:YapDatabaseExtensionsOrderKey];
		[internalChangeset setObject:extensionDependencies forKey:YapDatabaseExtensionDependenciesKey];
	}
	
	if (registeredMemoryTablesChanged)
	{
		if (internalChangeset == nil)
			internalChangeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForInternalChangeset];
		
		[internalChangeset setObject:registeredMemoryTables forKey:YapDatabaseRegisteredMemoryTablesKey];
	}
	
	// Step 2 of 2 - Process database changes
	//
	// Throughout the readwrite transaction we've been keeping a list of what changed.
	// Copy this change information into the changeset for processing by other connections.
	
	if ([objectChanges count]      > 0 ||
		[metadataChanges count]    > 0 ||
		[removedKeys count]        > 0 ||
		[removedCollections count] > 0 ||
	    [removedRowids count]      > 0 || allKeysRemoved)
	{
		if (internalChangeset == nil)
			internalChangeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForInternalChangeset];
		
		if (externalChangeset == nil)
			externalChangeset = [NSMutableDictionary dictionaryWithSharedKeySet:sharedKeySetForExternalChangeset];
		
		if ([objectChanges count] > 0)
		{
			internalChangeset[YapDatabaseObjectChangesKey] = objectChanges;
			
			YapSet *immutableObjectChanges = [[YapSet alloc] initWithDictionary:objectChanges];
			externalChangeset[YapDatabaseObjectChangesKey] = immutableObjectChanges;
		}
		
		if ([metadataChanges count] > 0)
		{
			internalChangeset[YapDatabaseMetadataChangesKey] = metadataChanges;
			
			YapSet *immutableMetadataChanges = [[YapSet alloc] initWithDictionary:metadataChanges];
			externalChangeset[YapDatabaseMetadataChangesKey] = immutableMetadataChanges;
		}
		
		if ([removedKeys count] > 0)
		{
			internalChangeset[YapDatabaseRemovedKeysKey] = removedKeys;
			
			YapSet *immutableRemovedKeys = [[YapSet alloc] initWithSet:removedKeys];
			externalChangeset[YapDatabaseRemovedKeysKey] = immutableRemovedKeys;
		}
		
		if ([removedCollections count] > 0)
		{
			internalChangeset[YapDatabaseRemovedCollectionsKey] = removedCollections;
			
			YapSet *immutableRemovedCollections = [[YapSet alloc] initWithSet:removedCollections];
			externalChangeset[YapDatabaseRemovedCollectionsKey] = immutableRemovedCollections;
		}
		
		if ([removedRowids count] > 0)
		{
			internalChangeset[YapDatabaseRemovedRowidsKey] = removedRowids;
		}
		
		if (allKeysRemoved)
		{
			internalChangeset[YapDatabaseAllKeysRemovedKey] = @(YES);
			externalChangeset[YapDatabaseAllKeysRemovedKey] = @(YES);
		}
	}
	
	*internalChangesetPtr = internalChangeset;
	*externalChangesetPtr = externalChangeset;
}

/**
 * This method is invoked with the changeset from a sibling connection.
 * The connection should update any in-memory components (such as the cache) to properly reflect the changeset.
 *
 * @see getInternalChangeset:externalChangeset:
**/
- (void)processChangeset:(NSDictionary *)changeset
{
	// Did registered extensions change ?
	
	NSDictionary *changeset_registeredExtensions = [changeset objectForKey:YapDatabaseRegisteredExtensionsKey];
	if (changeset_registeredExtensions)
	{
		// Retain new lists
		
		registeredExtensions = changeset_registeredExtensions;
		extensionsOrder = [changeset objectForKey:YapDatabaseExtensionsOrderKey];
		extensionDependencies = [changeset objectForKey:YapDatabaseExtensionDependenciesKey];
		
		// Remove any extensions that have been dropped
		
		for (NSString *extName in [extensions allKeys])
		{
			if ([registeredExtensions objectForKey:extName] == nil)
			{
				YDBLogVerbose(@"Dropping extension: %@", extName);
				
				[extensions removeObjectForKey:extName];
			}
		}
		
		// Make a note if there are extensions for which we haven't instantiated an extConnection instance.
		// We lazily load these later, if needed.
		
		extensionsReady = ([registeredExtensions count] == [extensions count]);
	}
	
	// Did registered memory tables change ?
	
	NSDictionary *changeset_registeredMemoryTables = [changeset objectForKey:YapDatabaseRegisteredMemoryTablesKey];
	if (changeset_registeredMemoryTables)
	{
		registeredMemoryTables = changeset_registeredMemoryTables;
	}
	
	// Allow extensions to process their individual changesets
	
	NSDictionary *changeset_extensions = [changeset objectForKey:YapDatabaseExtensionsKey];
	if (changeset_extensions)
	{
		// Use existing extensions (extensions ivar, not [self extensions]).
		// There's no need to create any new extConnections at this point.
		
		[extensions enumerateKeysAndObjectsUsingBlock:^(id extName, id extConnectionObj, BOOL *stop) {
			
			__unsafe_unretained YapDatabaseExtensionConnection *extConnection = extConnectionObj;
			
			NSDictionary *changeset_extensions_extName = [changeset_extensions objectForKey:extName];
			if (changeset_extensions_extName)
			{
				[extConnection processChangeset:changeset_extensions_extName];
			}
		}];
	}
	
	// Process normal database changset information
	
	NSDictionary *changeset_objectChanges   =  [changeset objectForKey:YapDatabaseObjectChangesKey];
	NSDictionary *changeset_metadataChanges =  [changeset objectForKey:YapDatabaseMetadataChangesKey];
	
	NSSet *changeset_removedRowids      = [changeset objectForKey:YapDatabaseRemovedRowidsKey];
	NSSet *changeset_removedKeys        = [changeset objectForKey:YapDatabaseRemovedKeysKey];
	NSSet *changeset_removedCollections = [changeset objectForKey:YapDatabaseRemovedCollectionsKey];
	
	BOOL changeset_allKeysRemoved = [[changeset objectForKey:YapDatabaseAllKeysRemovedKey] boolValue];
	
	BOOL hasObjectChanges      = [changeset_objectChanges count] > 0;
	BOOL hasMetadataChanges    = [changeset_metadataChanges count] > 0;
	BOOL hasRemovedKeys        = [changeset_removedKeys count] > 0;
	BOOL hasRemovedCollections = [changeset_removedCollections count] > 0;
	
	// Update keyCache
	
	if (changeset_allKeysRemoved)
	{
		// Shortcut: Everything was removed from the database
		
		[keyCache removeAllObjects];
	}
	else
	{
		if (hasRemovedCollections)
		{
			__block NSMutableArray *toRemove = nil;
			[keyCache enumerateKeysAndObjectsWithBlock:^(id key, id obj, BOOL *stop) {
				
				__unsafe_unretained NSNumber *rowidNumber = (NSNumber *)key;
				__unsafe_unretained YapCollectionKey *collectionKey = (YapCollectionKey *)obj;
				
				if ([changeset_removedCollections containsObject:collectionKey.collection])
				{
					if (toRemove == nil)
						toRemove = [NSMutableArray array];
					
					[toRemove addObject:rowidNumber];
				}
			}];
			
			[keyCache removeObjectsForKeys:toRemove];
		}
		
		if (changeset_removedRowids)
		{
			[changeset_removedRowids enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
				
				[keyCache removeObjectForKey:obj];
			}];
		}
	}
	
	// Update objectCache
	
	if (changeset_allKeysRemoved && !hasObjectChanges)
	{
		// Shortcut: Everything was removed from the database
		
		[objectCache removeAllObjects];
	}
	else if (hasObjectChanges && !hasRemovedKeys && !hasRemovedCollections && !changeset_allKeysRemoved)
	{
		// Shortcut: Nothing was removed from the database.
		// So we can simply enumerate over the changes and update the cache inline as needed.
		
		id yapNull = [YapNull null];    // value == yapNull  : setPrimitive or containment policy
		id yapTouch = [YapTouch touch]; // value == yapTouch : touchObjectForKey: was used
		
		BOOL isPolicyContainment = (objectPolicy == YapDatabasePolicyContainment);
		BOOL isPolicyShare       = (objectPolicy == YapDatabasePolicyShare);
		
		[changeset_objectChanges enumerateKeysAndObjectsUsingBlock:^(id key, id newObject, BOOL *stop) {
			
			__unsafe_unretained YapCollectionKey *cacheKey = (YapCollectionKey *)key;
			
			if ([objectCache containsKey:cacheKey])
			{
				if (newObject == yapNull)
				{
					[objectCache removeObjectForKey:cacheKey];
				}
				else if (newObject != yapTouch)
				{
					if (isPolicyContainment) {
						[objectCache removeObjectForKey:cacheKey];
					}
					else if (isPolicyShare) {
						[objectCache setObject:newObject forKey:cacheKey];
					}
					else // if (isPolicyCopy)
					{
						if ([newObject conformsToProtocol:@protocol(NSCopying)])
							[objectCache setObject:[newObject copy] forKey:cacheKey];
						else
							[objectCache removeObjectForKey:cacheKey];
					}
				}
			}
		}];
	}
	else if (hasObjectChanges || hasRemovedKeys || hasRemovedCollections)
	{
		NSUInteger updateCapacity = MIN([objectCache count], [changeset_objectChanges count]);
		NSUInteger removeCapacity = MIN([objectCache count], [changeset_removedKeys count]);
		
		NSMutableArray *keysToUpdate = [NSMutableArray arrayWithCapacity:updateCapacity];
		NSMutableArray *keysToRemove = [NSMutableArray arrayWithCapacity:removeCapacity];
		
		[objectCache enumerateKeysWithBlock:^(id key, BOOL *stop) {
			
			// Order matters.
			// Consider the following database change:
			//
			// [transaction removeAllObjectsInAllCollections];
			// [transaction setObject:obj forKey:key inCollection:collection];
			
			__unsafe_unretained YapCollectionKey *cacheKey = (YapCollectionKey *)key;
			
			if ([changeset_objectChanges objectForKey:cacheKey])
			{
				[keysToUpdate addObject:key];
			}
			else if ([changeset_removedKeys containsObject:cacheKey] ||
					 [changeset_removedCollections containsObject:cacheKey.collection] || changeset_allKeysRemoved)
			{
				[keysToRemove addObject:key];
			}
		}];
		
		[objectCache removeObjectsForKeys:keysToRemove];
		
		id yapNull = [YapNull null];    // value == yapNull  : setPrimitive or containment policy
		id yapTouch = [YapTouch touch]; // value == yapTouch : touchObjectForKey: was used
		
		BOOL isPolicyContainment = (objectPolicy == YapDatabasePolicyContainment);
		BOOL isPolicyShare       = (objectPolicy == YapDatabasePolicyShare);
		
		for (YapCollectionKey *cacheKey in keysToUpdate)
		{
			id newObject = [changeset_objectChanges objectForKey:cacheKey];
			
			if (newObject == yapNull)
			{
				[objectCache removeObjectForKey:cacheKey];
			}
			else if (newObject != yapTouch)
			{
				if (isPolicyContainment) {
					[objectCache removeObjectForKey:cacheKey];
				}
				else if (isPolicyShare) {
					[objectCache setObject:newObject forKey:cacheKey];
				}
				else // if (isPolicyCopy)
				{
					if ([newObject conformsToProtocol:@protocol(NSCopying)])
						[objectCache setObject:[newObject copy] forKey:cacheKey];
					else
						[objectCache removeObjectForKey:cacheKey];
				}
			}
		}
	}
	
	// Update metadataCache
	
	if (changeset_allKeysRemoved && !hasMetadataChanges)
	{
		// Shortcut: Everything was removed from the database
		
		[metadataCache removeAllObjects];
	}
	else if (hasMetadataChanges && !hasRemovedKeys && !hasRemovedCollections && !changeset_allKeysRemoved)
	{
		// Shortcut: Nothing was removed from the database.
		// So we can simply enumerate over the changes and update the cache inline as needed.
		
		id yapNull = [YapNull null];    // value == yapNull  : setPrimitive or containment policy
		id yapTouch = [YapTouch touch]; // value == yapTouch : touchObjectForKey: was used
		
		BOOL isPolicyContainment = (metadataPolicy == YapDatabasePolicyContainment);
		BOOL isPolicyShare       = (metadataPolicy == YapDatabasePolicyShare);
		
		[changeset_metadataChanges enumerateKeysAndObjectsUsingBlock:^(id key, id newMetadata, BOOL *stop) {
			
			__unsafe_unretained YapCollectionKey *cacheKey = (YapCollectionKey *)key;
			
			if ([metadataCache containsKey:cacheKey])
			{
				if (newMetadata == yapNull)
				{
					[metadataCache removeObjectForKey:cacheKey];
				}
				else if (newMetadata != yapTouch)
				{
					if (isPolicyContainment) {
						[metadataCache removeObjectForKey:cacheKey];
					}
					else if (isPolicyShare) {
						[metadataCache setObject:newMetadata forKey:cacheKey];
					}
					else // if (isPolicyCopy)
					{
						if ([newMetadata conformsToProtocol:@protocol(NSCopying)])
							[metadataCache setObject:[newMetadata copy] forKey:cacheKey];
						else
							[metadataCache removeObjectForKey:cacheKey];
					}
				}
			}
		}];
	}
	else if (hasMetadataChanges || hasRemovedKeys || hasRemovedCollections)
	{
		NSUInteger updateCapacity = MIN([metadataCache count], [changeset_metadataChanges count]);
		NSUInteger removeCapacity = MIN([metadataCache count], [changeset_removedKeys count]);
		
		NSMutableArray *keysToUpdate = [NSMutableArray arrayWithCapacity:updateCapacity];
		NSMutableArray *keysToRemove = [NSMutableArray arrayWithCapacity:removeCapacity];
		
		[metadataCache enumerateKeysWithBlock:^(id key, BOOL *stop) {
			
			// Order matters.
			// Consider the following database change:
			//
			// [transaction removeAllObjectsInAllCollections];
			// [transaction setObject:obj forKey:key inCollection:collection];
			
			__unsafe_unretained YapCollectionKey *cacheKey = (YapCollectionKey *)key;
			
			if ([changeset_metadataChanges objectForKey:cacheKey])
			{
				[keysToUpdate addObject:key];
			}
			else if ([changeset_removedKeys containsObject:cacheKey] ||
					 [changeset_removedCollections containsObject:cacheKey.collection] || changeset_allKeysRemoved)
			{
				[keysToRemove addObject:key];
			}
		}];
		
		[metadataCache removeObjectsForKeys:keysToRemove];
		
		id yapNull = [YapNull null];    // value == yapNull  : setPrimitive or containment policy
		id yapTouch = [YapTouch touch]; // value == yapTouch : touchObjectForKey: was used
		
		BOOL isPolicyContainment = (metadataPolicy == YapDatabasePolicyContainment);
		BOOL isPolicyShare       = (metadataPolicy == YapDatabasePolicyShare);
		
		for (YapCollectionKey *cacheKey in keysToUpdate)
		{
			id newMetadata = [changeset_metadataChanges objectForKey:cacheKey];
			
			if (newMetadata == yapNull)
			{
				[metadataCache removeObjectForKey:cacheKey];
			}
			else if (newMetadata != yapTouch)
			{
				if (isPolicyContainment) {
					[metadataCache removeObjectForKey:cacheKey];
				}
				else if (isPolicyShare) {
					[metadataCache setObject:newMetadata forKey:cacheKey];
				}
				else // if (isPolicyCopy)
				{
					if ([newMetadata conformsToProtocol:@protocol(NSCopying)])
						[metadataCache setObject:[newMetadata copy] forKey:cacheKey];
					else
						[metadataCache removeObjectForKey:cacheKey];
				}
			}
		}
	}
}

/**
 * Internal method.
 *
 * This method is invoked with the changeset from a sibling connection.
**/
- (void)noteCommittedChanges:(NSDictionary *)changeset
{
	// This method must be invoked from within connectionQueue.
	// It may be invoked from:
	//
	// 1. [database noteCommittedChanges:fromConnection:]
	//   via dispatch_async(connectionQueue, ...)
	//
	// 2. [self  preReadTransaction:]
	//   via dispatch_X(connectionQueue) -> dispatch_sync(database->snapshotQueue)
	//
	// 3. [self preReadWriteTransaction:]
	//   via dispatch_X(connectionQueue) -> dispatch_sync(database->snapshotQueue)
	//
	// In case 1 (the common case) we can see IsOnConnectionQueueKey.
	// In case 2 & 3 (the edge cases) we can see IsOnSnapshotQueueKey.
	
	NSAssert(dispatch_get_specific(IsOnConnectionQueueKey) ||
			 dispatch_get_specific(database->IsOnSnapshotQueueKey), @"Must be invoked within connectionQueue");
	
	// Grab the new snapshot.
	// This tells us the minimum snapshot we could get if we started a transaction right now.
	
	uint64_t changesetSnapshot = [[changeset objectForKey:YapDatabaseSnapshotKey] unsignedLongLongValue];
	
	if (changesetSnapshot <= snapshot)
	{
		// We already noted this changeset.
		//
		// There is a "race condition" that occasionally happens when a readonly transaction is started
		// around the same instant a readwrite transaction finishes committing its changes to disk.
		// The readonly transaction enters our transaction state queue (to start) before
		// the readwrite transaction enters our transaction state queue (to finish).
		// However the readonly transaction gets a database snapshot post readwrite commit.
		// That is, the readonly transaction can read the changes from the readwrite transaction at the sqlite layer,
		// even though the readwrite transaction hasn't completed within the yap database layer.
		//
		// This race condition is handled automatically within the preReadTransaction method.
		// In fact, it invokes this method to handle the race condition.
		// Thus this method could be invoked twice to handle the same changeset.
		// So catching it here and ignoring it is simply a minor optimization to avoid duplicate work.
		
		YDBLogVerbose(@"Ignoring previously processed changeset %lu for connection %@, database %@",
		              (unsigned long)changesetSnapshot, self, database);
		
		return;
	}
	
	if (longLivedReadTransaction)
	{
		if (dispatch_get_specific(database->IsOnSnapshotQueueKey))
		{
			// This method is being invoked from preReadTransaction:.
			// We are to process the changeset for it.
			
			[processedChangesets addObject:changeset];
		}
		else
		{
			// This method is being invoked from [database noteCommittedChanges:].
			// We cannot process the changeset yet.
			// We must wait for the longLivedReadTransaction to be reset.
			
			YDBLogVerbose(@"Storing pending changeset %lu for connection %@, database %@",
			              (unsigned long)changesetSnapshot, self, database);
			
			[pendingChangesets addObject:changeset];
			return;
		}
	}
	
	// Changeset processing
	
	YDBLogVerbose(@"Processing changeset %lu for connection %@, database %@",
	              (unsigned long)changesetSnapshot, self, database);
	
	snapshot = changesetSnapshot;
	[self processChangeset:changeset];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Changeset Inspection
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)hasChangeForCollection:(NSString *)collection
               inNotifications:(NSArray *)notifications
        includingObjectChanges:(BOOL)includeObjectChanges
               metadataChanges:(BOOL)includeMetadataChanges
{
	if (collection == nil)
		collection = @"";
	
	for (NSNotification *notification in notifications)
	{
		if (![notification isKindOfClass:[NSNotification class]])
		{
			YDBLogWarn(@"%@ - notifications parameter contains non-NSNotification object", THIS_METHOD);
			continue;
		}
		
		NSDictionary *changeset = notification.userInfo;
		
		if (includeObjectChanges)
		{
			YapSet *changeset_objectChanges = [changeset objectForKey:YapDatabaseObjectChangesKey];
			for (YapCollectionKey *collectionKey in changeset_objectChanges)
			{
				if ([collectionKey.collection isEqualToString:collection])
				{
					return YES;
				}
			}
		}
		
		if (includeMetadataChanges)
		{
			YapSet *changeset_metadataChanges = [changeset objectForKey:YapDatabaseMetadataChangesKey];
			for (YapCollectionKey *collectionKey in changeset_metadataChanges)
			{
				if ([collectionKey.collection isEqualToString:collection])
				{
					return YES;
				}
			}
		}
		
		YapSet *changeset_removedKeys = [changeset objectForKey:YapDatabaseRemovedKeysKey];
		for (YapCollectionKey *collectionKey in changeset_removedKeys)
		{
			if ([collectionKey.collection isEqualToString:collection])
			{
				return YES;
			}
		}
		
		YapSet *changeset_removedCollections = [changeset objectForKey:YapDatabaseRemovedCollectionsKey];
		if ([changeset_removedCollections containsObject:collection])
			return YES;
		
		BOOL changeset_allKeysRemoved = [[changeset objectForKey:YapDatabaseAllKeysRemovedKey] boolValue];
		if (changeset_allKeysRemoved)
			return YES;
	}
	
	return NO;
}

- (BOOL)hasChangeForCollection:(NSString *)collection inNotifications:(NSArray *)notifications
{
	return [self hasChangeForCollection:collection
	                    inNotifications:notifications
	             includingObjectChanges:YES
	                    metadataChanges:YES];
}

- (BOOL)hasObjectChangeForCollection:(NSString *)collection inNotifications:(NSArray *)notifications
{
	return [self hasChangeForCollection:collection
	                    inNotifications:notifications
	             includingObjectChanges:YES
	                    metadataChanges:NO];
}

- (BOOL)hasMetadataChangeForCollection:(NSString *)collection inNotifications:(NSArray *)notifications
{
	return [self hasChangeForCollection:collection
	                    inNotifications:notifications
	             includingObjectChanges:NO
	                    metadataChanges:YES];
}

// Query for a change to a particular key/collection tuple

- (BOOL)hasChangeForKey:(NSString *)key
           inCollection:(NSString *)collection
        inNotifications:(NSArray *)notifications
 includingObjectChanges:(BOOL)includeObjectChanges
        metadataChanges:(BOOL)includeMetadataChanges
{
	if (key == nil) return NO;
	if (collection == nil)
		collection = @"";
	
	YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
	
	for (NSNotification *notification in notifications)
	{
		if (![notification isKindOfClass:[NSNotification class]])
		{
			YDBLogWarn(@"%@ - notifications parameter contains non-NSNotification object", THIS_METHOD);
			continue;
		}
		
		NSDictionary *changeset = notification.userInfo;
		
		if (includeObjectChanges)
		{
			YapSet *changeset_objectChanges = [changeset objectForKey:YapDatabaseObjectChangesKey];
			if ([changeset_objectChanges containsObject:collectionKey])
				return YES;
		}
		
		if (includeMetadataChanges)
		{
			YapSet *changeset_metadataChanges = [changeset objectForKey:YapDatabaseMetadataChangesKey];
			if ([changeset_metadataChanges containsObject:collectionKey])
				return YES;
		}
		
		YapSet *changeset_removedKeys = [changeset objectForKey:YapDatabaseRemovedKeysKey];
		if ([changeset_removedKeys containsObject:collectionKey])
			return YES;
		
		YapSet *changeset_removedCollections = [changeset objectForKey:YapDatabaseRemovedCollectionsKey];
		if ([changeset_removedCollections containsObject:collection])
			return YES;
		
		BOOL changeset_allKeysRemoved = [[changeset objectForKey:YapDatabaseAllKeysRemovedKey] boolValue];
		if (changeset_allKeysRemoved)
			return YES;
	}
	
	return NO;
}

- (BOOL)hasChangeForKey:(NSString *)key
           inCollection:(NSString *)collection
        inNotifications:(NSArray *)notifications
{
	return [self hasChangeForKey:key
	                inCollection:collection
	             inNotifications:notifications
	      includingObjectChanges:YES
	             metadataChanges:YES];
}

- (BOOL)hasObjectChangeForKey:(NSString *)key
                 inCollection:(NSString *)collection
              inNotifications:(NSArray *)notifications
{
	return [self hasChangeForKey:key
	                inCollection:collection
	             inNotifications:notifications
	      includingObjectChanges:YES
	             metadataChanges:NO];
}

- (BOOL)hasMetadataChangeForKey:(NSString *)key
                   inCollection:(NSString *)collection
                inNotifications:(NSArray *)notifications
{
	return [self hasChangeForKey:key
	                inCollection:collection
	             inNotifications:notifications
	      includingObjectChanges:NO
	             metadataChanges:YES];
}

// Query for a change to a particular set of keys in a collection

- (BOOL)hasChangeForAnyKeys:(NSSet *)keys
               inCollection:(NSString *)collection
            inNotifications:(NSArray *)notifications
     includingObjectChanges:(BOOL)includeObjectChanges
            metadataChanges:(BOOL)includeMetadataChanges
{
	if ([keys count] == 0) return NO;
	if (collection == nil)
		collection = @"";
	
	for (NSNotification *notification in notifications)
	{
		if (![notification isKindOfClass:[NSNotification class]])
		{
			YDBLogWarn(@"%@ - notifications parameter contains non-NSNotification object", THIS_METHOD);
			continue;
		}
		
		NSDictionary *changeset = notification.userInfo;
		
		if (includeObjectChanges)
		{
			YapSet *changeset_objectChanges = [changeset objectForKey:YapDatabaseObjectChangesKey];
			for (YapCollectionKey *collectionKey in changeset_objectChanges)
			{
				if ([collectionKey.collection isEqualToString:collection])
				{
					if ([keys containsObject:collectionKey.key])
					{
						return YES;
					}
				}
			}
		}
		
		if (includeMetadataChanges)
		{
			YapSet *changeset_metadataChanges = [changeset objectForKey:YapDatabaseMetadataChangesKey];
			for (YapCollectionKey *collectionKey in changeset_metadataChanges)
			{
				if ([collectionKey.collection isEqualToString:collection])
				{
					if ([keys containsObject:collectionKey.key])
					{
						return YES;
					}
				}
			}
		}
		
		YapSet *changeset_removedKeys = [changeset objectForKey:YapDatabaseRemovedKeysKey];
		for (YapCollectionKey *collectionKey in changeset_removedKeys)
		{
			if ([collectionKey.collection isEqualToString:collection])
			{
				if ([keys containsObject:collectionKey.key])
				{
					return YES;
				}
			}
		}
		
		YapSet *changeset_removedCollections = [changeset objectForKey:YapDatabaseRemovedCollectionsKey];
		if ([changeset_removedCollections containsObject:collection])
			return YES;
		
		BOOL changeset_allKeysRemoved = [[changeset objectForKey:YapDatabaseAllKeysRemovedKey] boolValue];
		if (changeset_allKeysRemoved)
			return YES;
	}
	
	return NO;
}

- (BOOL)hasChangeForAnyKeys:(NSSet *)keys
               inCollection:(NSString *)collection
            inNotifications:(NSArray *)notifications
{
	return [self hasChangeForAnyKeys:keys
	                    inCollection:collection
	                 inNotifications:notifications
	          includingObjectChanges:YES
	                 metadataChanges:YES];
}

- (BOOL)hasObjectChangeForAnyKeys:(NSSet *)keys
                     inCollection:(NSString *)collection
                  inNotifications:(NSArray *)notifications
{
	return [self hasChangeForAnyKeys:keys
	                    inCollection:collection
	                 inNotifications:notifications
	          includingObjectChanges:YES
	                 metadataChanges:NO];
}

- (BOOL)hasMetadataChangeForAnyKeys:(NSSet *)keys
                       inCollection:(NSString *)collection
                    inNotifications:(NSArray *)notifications
{
	return [self hasChangeForAnyKeys:keys
	                    inCollection:collection
	                 inNotifications:notifications
	          includingObjectChanges:NO
	                 metadataChanges:YES];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Extensions
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Creates or fetches the extension with the given name.
 * If this connection has not yet initialized the proper extensions connection, it is done automatically.
 *
 * @return
 *     A subclass of YapDatabaseExtensionConnection,
 *     according to the type of extension registered under the given name.
 *
 * One must register an extension with the database before it can be accessed from within connections or transactions.
 * After registration everything works automatically using just the registered extension name.
 *
 * @see [YapDatabase registerExtension:withName:]
**/
- (id)extension:(NSString *)extName
{
	// This method is PUBLIC.
	//
	// This method returns a subclass of YapDatabaseExtensionConnection.
	// To get:
	// - YapDatabaseExtension            => [database registeredExtension:@"registeredNameOfExtension"]
	// - YapDatabaseExtensionConnection  => [databaseConnection extension:@"registeredNameOfExtension"]
	// - YapDatabaseExtensionTransaction => [databaseTransaction extension:@"registeredNameOfExtension"]
	
	__block id extConnection = nil;
	
	dispatch_block_t block = ^{
		
		extConnection = [extensions objectForKey:extName];
		
		if (!extConnection && !extensionsReady)
		{
			// We don't have an existing connection for the extension.
			// Create one (if we can).
			
			YapDatabaseExtension *ext = [registeredExtensions objectForKey:extName];
			if (ext)
			{
				extConnection = [ext newConnection:self];
				[extensions setObject:extConnection forKey:extName];
			}
		}
	};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return extConnection;
}

- (id)ext:(NSString *)extensionName
{
	// The "+ (void)load" method swizzles the implementation of this class
	// to point to the implementation of the extension: method.
	//
	// So the two methods are literally the same thing.
	
	return [self extension:extensionName]; // This method is swizzled !
}

- (NSDictionary *)extensions
{
	// This method is INTERNAL
	
	if (!extensionsReady)
	{
		[registeredExtensions enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
			
			__unsafe_unretained NSString *extName = key;
			__unsafe_unretained YapDatabaseExtension *ext = obj;
			
			if ([extensions objectForKey:extName] == nil)
			{
				id extConnection = [ext newConnection:self];
				[extensions setObject:extConnection forKey:extName];
			}
		}];
		
		extensionsReady = YES;
	}
	
	return extensions;
}

- (BOOL)registerExtension:(YapDatabaseExtension *)extension withName:(NSString *)extensionName
{
	NSAssert(dispatch_get_specific(database->IsOnWriteQueueKey), @"Must go through writeQueue.");
	
	__block BOOL result = NO;
	
	dispatch_sync(connectionQueue, ^{ @autoreleasepool {
	
		YapDatabaseReadWriteTransaction *transaction = [self newReadWriteTransaction];
		[self preReadWriteTransaction:transaction];
		
		// Set the registeredName now.
		// The extension will need this in order to perform the registration tasks such as creating tables, etc.
		extension.registeredName = extensionName;
		extension.registeredDatabase = database;
		
		YapDatabaseExtensionConnection *extensionConnection;
		YapDatabaseExtensionTransaction *extensionTransaction;
		
		extensionConnection = [extension newConnection:self];
		extensionTransaction = [extensionConnection newReadWriteTransaction:transaction];
		
		BOOL needsClassValue = NO;
		[self willRegisterExtension:extension
		                   withName:extensionName
		                transaction:transaction
		            needsClassValue:&needsClassValue];
		
		result = [extensionTransaction createIfNeeded];
		
		if (result)
		{
			[self didRegisterExtension:extension
			                  withName:extensionName
			               transaction:transaction
			           needsClassValue:needsClassValue];
			
			[self addRegisteredExtensionConnection:extensionConnection withName:extensionName];
			[transaction addRegisteredExtensionTransaction:extensionTransaction withName:extensionName];
		}
		else
		{
			// Registration failed.
			
			extension.registeredName = nil;
			extension.registeredDatabase = nil;
			
			[transaction rollback];
		}
		
		[self postReadWriteTransaction:transaction];
		registeredExtensionsChanged = NO;
	}});
	
	return result;
}

- (void)unregisterExtensionWithName:(NSString *)extensionName
{
	NSAssert(dispatch_get_specific(database->IsOnWriteQueueKey), @"Must go through writeQueue.");
	
	dispatch_sync(connectionQueue, ^{ @autoreleasepool {
		
		YapDatabaseReadWriteTransaction *transaction = [self newReadWriteTransaction];
		[self preReadWriteTransaction:transaction];
		
		// Unregister the given extension
		
		YapDatabaseExtension *extension = [registeredExtensions objectForKey:extensionName];
		
		[self _unregisterExtensionWithName:extensionName transaction:transaction];
		extension.registeredName = nil;
		extension.registeredDatabase = nil;
		
		// Automatically unregister any extensions that were dependent upon this one.
		
		NSMutableArray *extensionNameStack = [NSMutableArray arrayWithCapacity:1];
		[extensionNameStack addObject:extensionName];
		
		do
		{
			NSString *currentExtensionName = [extensionNameStack lastObject];
			
			__block NSString *dependentExtName = nil;
			[extensionDependencies enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop){
				
			//	__unsafe_unretained NSString *extName = (NSString *)key;
				__unsafe_unretained NSSet *extDependencies = (NSSet *)obj;
				
				if ([extDependencies containsObject:currentExtensionName])
				{
					dependentExtName = (NSString *)key;
					*stop = YES;
				}
			}];
			
			if (dependentExtName)
			{
				// We found an extension that was dependent upon the one we just unregistered.
				// So we need to unregister it too.
				
				YapDatabaseExtension *dependentExt = [registeredExtensions objectForKey:dependentExtName];
				
				[self _unregisterExtensionWithName:dependentExtName transaction:transaction];
				dependentExt.registeredName = nil;
				
				// And now we need to check and see if there were any extensions dependent upon this new one.
				// So we add it to the top of the stack, and continue our search.
				
				[extensionNameStack addObject:dependentExtName];
			}
			else
			{
				[extensionNameStack removeLastObject];
			}
			
		} while ([extensionNameStack count] > 0);
		
		
		// Complete the transaction
		[self postReadWriteTransaction:transaction];
		
		// And reset the registeredExtensionsChanged ivar.
		// The above method already processed it, and included the appropriate information in the changeset.
		registeredExtensionsChanged = NO;
	}});
}

- (void)_unregisterExtensionWithName:(NSString *)extensionName
                         transaction:(YapDatabaseReadWriteTransaction *)transaction
{
	NSString *className = nil;
	Class class = NULL;
	
	BOOL wasPersistent;
	
	YapMemoryTableTransaction *memoryTableTransaction = [transaction yapMemoryTableTransaction];
	YapCollectionKey *classKey = [[YapCollectionKey alloc] initWithCollection:extensionName key:ExtKey_class];
	
	className = [memoryTableTransaction objectForKey:classKey];
	if (className)
	{
		wasPersistent = NO;
	}
	else
	{
		className = [transaction stringValueForKey:ExtKey_class extension:extensionName];
		wasPersistent = YES;
	}
	
	class = NSClassFromString(className);
	
	if (className == nil)
	{
		YDBLogWarn(@"Unable to unregister extension(%@). Doesn't appear to be registered.", extensionName);
	}
	else if (class == NULL)
	{
		YDBLogError(@"Unable to unregister extension(%@) with unknown class(%@)", extensionName, className);
	}
	if (![class isSubclassOfClass:[YapDatabaseExtension class]])
	{
		YDBLogError(@"Unable to unregister extension(%@) with improper class(%@)", extensionName, className);
	}
	else
	{
		// Drop tables
		[class dropTablesForRegisteredName:extensionName withTransaction:transaction wasPersistent:wasPersistent];
		
		// Drop preferences
		if (wasPersistent)
		{
			// remove rows in yap2 table (where extension == extensionName)
			[transaction removeAllValuesForExtension:extensionName];
		}
		else
		{
			// remove rows in yap memory table (where collectionKey.collection == extensionName)
			NSMutableArray *keysToRemove = [NSMutableArray array];
			
			[memoryTableTransaction enumerateKeysWithBlock:^(id key, BOOL *stop) {
				
				__unsafe_unretained YapCollectionKey *ck = (YapCollectionKey *)key;
				if ([ck.collection isEqualToString:extensionName])
				{
					[keysToRemove addObject:ck];
				}
			}];
			
			[memoryTableTransaction removeObjectsForKeys:keysToRemove];
		}
		
		// Remove from registeredExtensions, extensionsOrder & extensionDependencies (if needed)
		[self didUnregisterExtensionWithName:extensionName];
		
		// Remove YapDatabaseExtensionConnection subclass instance (if needed)
		[self removeRegisteredExtensionConnectionWithName:extensionName];
		
		// Remove YapDatabaseExtensionTransaction subclass instance (if needed)
		[transaction removeRegisteredExtensionTransactionWithName:extensionName];
	}
}

- (void)willRegisterExtension:(YapDatabaseExtension *)extension
                     withName:(NSString *)extensionName
                transaction:(YapDatabaseReadWriteTransaction *)transaction
              needsClassValue:(BOOL *)needsClassValuePtr
{
	// This method is INTERNAL
	
	// Check to see if we should create the YapMemoryTable.
	// We create this on demand the first time an extension is registered.
	
	if ([registeredMemoryTables objectForKey:@"yap"] == nil)
	{
		YapMemoryTable *memoryTable = [[YapMemoryTable alloc] initWithKeyClass:[YapCollectionKey class]];
		
		[self registerMemoryTable:memoryTable withName:@"yap"];
	}
	
	// Special handling for non-persistent (in-memory only) extensions.
	
	if (![extension isPersistent])
	{
		// First time registration
		*needsClassValuePtr = YES;
		return;
	}
	
	// The class name of every registered extension is recorded in the yap2 table.
	// We ensure that re-registrations under the same name use the same extension class.
	// If we detect a change, we auto-unregister the previous extension.
	//
	// Note: @"class" is a reserved key for all extensions.
	
	NSString *prevExtensionClassName = [transaction stringValueForKey:ExtKey_class extension:extensionName];
	if (prevExtensionClassName == nil)
	{
		// First time registration
		*needsClassValuePtr = YES;
		return;
	}
	
	NSString *extensionClassName = NSStringFromClass([extension class]);
	
	if ([extensionClassName isEqualToString:prevExtensionClassName])
	{
		// Re-registration
		*needsClassValuePtr = NO;
		return;
	}
	
	NSArray *otherValidClassNames = [[extension class] previousClassNames];
	
	if ([otherValidClassNames containsObject:prevExtensionClassName])
	{
		// The extension class was renamed.
		// We should update the class value in the database.
		*needsClassValuePtr = YES;
		return;
	}
	
	YDBLogWarn(@"Dropping tables for previously registered extension with name(%@), class(%@) for new class(%@)",
	           extensionName, prevExtensionClassName, extensionClassName);
	
	Class prevExtensionClass = NSClassFromString(prevExtensionClassName);
	
	if (prevExtensionClass == NULL)
	{
		YDBLogError(@"Unable to drop tables for previously registered extension with name(%@), unknown class(%@)",
		            extensionName, prevExtensionClassName);
	}
	else if (![prevExtensionClass isSubclassOfClass:[YapDatabaseExtension class]])
	{
		YDBLogError(@"Unable to drop tables for previously registered extension with name(%@), invalid class(%@)",
		            extensionName, prevExtensionClassName);
	}
	else
	{
		// Drop tables
		[prevExtensionClass dropTablesForRegisteredName:extensionName withTransaction:transaction wasPersistent:YES];
		
		// Drop preferences (rows in yap2 table)
		[transaction removeAllValuesForExtension:extensionName];
	}
	
	*needsClassValuePtr = YES;
}

- (void)didRegisterExtension:(YapDatabaseExtension *)extension
                    withName:(NSString *)extensionName
                 transaction:(YapDatabaseReadWriteTransaction *)transaction
             needsClassValue:(BOOL)needsClassValue
{
	// This method is INTERNAL
	
	// Record the class name of the extension in the yap2 table (if needed)
	
	if (needsClassValue)
	{
		NSString *extensionClassName = NSStringFromClass([extension class]);
		
		if ([extension isPersistent])
		{
			[transaction setStringValue:extensionClassName forKey:ExtKey_class extension:extensionName];
		}
		else
		{
			YapCollectionKey *classKey = [[YapCollectionKey alloc] initWithCollection:extensionName key:ExtKey_class];
			[[transaction yapMemoryTableTransaction] setObject:extensionClassName forKey:classKey];
		}
	}
	
	// Update the list of registered extensions.
	
	NSMutableDictionary *newRegisteredExtensions = [registeredExtensions mutableCopy];
	[newRegisteredExtensions setObject:extension forKey:extensionName];
	
	registeredExtensions = [newRegisteredExtensions copy];
	extensionsOrder = [extensionsOrder arrayByAddingObject:extensionName];
	
	NSSet *dependencies = [extension dependencies];
	if (dependencies == nil)
		dependencies = [NSSet set];
	
	NSMutableDictionary *newExtensionDependencies = [extensionDependencies mutableCopy];
	[newExtensionDependencies setObject:dependencies forKey:extensionName];
	
	extensionDependencies = [newExtensionDependencies copy];
	
	extensionsReady = NO;
	sharedKeySetForExtensions = [NSDictionary sharedKeySetForKeys:[registeredExtensions allKeys]];
	
	// Set the registeredExtensionsChanged flag.
	// This will be consulted during the creation of the changeset,
	// and will cause us to add the updated registeredExtensions to the list of changes.
	// It will then get propogated to the database, and all other connections.
	
	registeredExtensionsChanged = YES;
}

- (void)didUnregisterExtensionWithName:(NSString *)extensionName
{
	// This method is INTERNAL
	
	if ([registeredExtensions objectForKey:extensionName])
	{
		NSMutableDictionary *newRegisteredExtensions = [registeredExtensions mutableCopy];
		[newRegisteredExtensions removeObjectForKey:extensionName];
		
		registeredExtensions = [newRegisteredExtensions copy];
		
		NSMutableArray *newExtensionsOrder = [extensionsOrder mutableCopy];
		[newExtensionsOrder removeObject:extensionName];
		
		extensionsOrder = [newExtensionsOrder copy];
		
		NSMutableDictionary *newExtensionDependencies = [extensionDependencies mutableCopy];
		[newExtensionDependencies removeObjectForKey:extensionName];
		
		extensionDependencies = [newExtensionDependencies copy];
		
		extensionsReady = NO;
		sharedKeySetForExtensions = [NSDictionary sharedKeySetForKeys:[registeredExtensions allKeys]];
		
		// Set the registeredExtensionsChanged flag.
		// This will be consulted during the creation of the changeset,
		// and will cause us to add the updated registeredExtensions to the list of changes.
		// It will then get propogated to the database, and all other connections.
		
		registeredExtensionsChanged = YES;
	}
}

- (void)addRegisteredExtensionConnection:(YapDatabaseExtensionConnection *)extConnection withName:(NSString *)extName
{
	// This method is INTERNAL
	
	if (extensions == nil)
		extensions = [[NSMutableDictionary alloc] init];
	
	[extensions setObject:extConnection forKey:extName];
}

- (void)removeRegisteredExtensionConnectionWithName:(NSString *)extName
{
	// This method is INTERNAL
	
	[extensions removeObjectForKey:extName];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Vacuum
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Upgrade Notice:
 *
 * The "auto_vacuum=FULL" was not properly set until YapDatabase v2.5.
 * And thus if you have an app that was using YapDatabase prior to this version,
 * then the existing database file will continue to operate in "auto_vacuum=NONE" mode.
 * This means the existing database file won't be properly truncated as you delete information from the db.
 * That is, the data will be removed, but the pages will be moved to the freelist,
 * and the file itself will remain the same size on disk. (I.e. the file size can grow, but not shrink.)
 * To correct this problem, you should run the vacuum operation is at least once.
 * After it is run, the "auto_vacuum=FULL" mode will be set,
 * and the database file size will automatically shrink in the future (as you delete data).
 *
 * @returns Result from "PRAGMA auto_vacuum;" command, as a readable string:
 *   - NONE
 *   - FULL
 *   - INCREMENTAL
 *   - UNKNOWN (future proofing)
 *
 * If the return value is NONE, then you should run the vacuum operation at some point
 * in order to properly reconfigure the database.
 *
 * Concerning Method Invocation:
 *
 * You can invoke this method as a standalone method on the connection:
 *
 *   NSString *value = [databaseConnection pragmaAutoVacuum]
 *
 * Or you can invoke this method within a transaction:
 *
 * [databaseConnection asyncReadWithBlock:^(YapDatabaseReadTransaction *transaction){
 *     NSString *value = [databaseConnection pragmaAutoVacuum];
 * }];
**/
- (NSString *)pragmaAutoVacuum
{
	__block int value = -1;
	
	dispatch_block_t block = ^{ @autoreleasepool {
	
		value = [YapDatabase pragma:@"auto_vacuum" using:db];
	}};
	
	if (dispatch_get_specific(IsOnConnectionQueueKey))
		block();
	else
		dispatch_sync(connectionQueue, block);
	
	return [YapDatabase pragmaValueForAutoVacuum:value];
}

/**
 * Performs a VACUUM on the sqlite database.
 *
 * This method operates as a synchronous ReadWrite "transaction".
 * That is, it behaves in a similar fashion, and you may treat it as if it is a ReadWrite transaction.
 *
 * For more infomation on the VACUUM operation, see the sqlite docs:
 * http://sqlite.org/lang_vacuum.html
 *
 * Remember that YapDatabase operates in WAL mode, with "auto_vacuum=FULL" set.
 *
 * @see pragmaAutoVacuum
**/
- (void)vacuum
{
	dispatch_sync(connectionQueue, ^{ @autoreleasepool {
		
		if (longLivedReadTransaction)
		{
			if (throwExceptionsForImplicitlyEndingLongLivedReadTransaction)
			{
				@throw [self implicitlyEndingLongLivedReadTransactionException];
			}
			else
			{
				YDBLogWarn(@"Implicitly ending long-lived read transaction on connection %@, database %@",
						   self, database);
				
				[self endLongLivedReadTransaction];
			}
		}
		
		__preWriteQueue(self);
		dispatch_sync(database->writeQueue, ^{ @autoreleasepool {
			
			[self preVacuum];
			
			int status;
			
			status = sqlite3_exec(db, "PRAGMA auto_vacuum = FULL;", NULL, NULL, NULL);
			if (status != SQLITE_OK)
			{
				YDBLogError(@"Error setting PRAGMA auto_vacuum: %d %s", status, sqlite3_errmsg(db));
			}
			
			YDBLogVerbose(@"Starting VACUUM ...");
			
			status = sqlite3_exec(db, "VACUUM;", NULL, NULL, NULL);
			if (status != SQLITE_OK)
			{
				YDBLogError(@"Error performing VACUUM: %d %s", status, sqlite3_errmsg(db));
			}
			
			YDBLogVerbose(@"VACUUM complete !");
			
			[self postVacuum];
			
		}}); // End dispatch_sync(database->writeQueue)
		__postWriteQueue(self);
	}});     // End dispatch_sync(connectionQueue)
}

/**
 * Performs a VACUUM on the sqlite database.
 *
 * This method operates as an asynchronous readWrite "transaction".
 * That is, it behaves in a similar fashion, and you may treat it as if it is a ReadWrite transaction.
 *
 * For more infomation on the VACUUM operation, see the sqlite docs:
 * http://sqlite.org/lang_vacuum.html
 *
 * Remember that YapDatabase operates in WAL mode, with "auto_vacuum=FULL" set.
 *
 * An optional completion block may be used.
 * The completionBlock will be invoked on the main thread (dispatch_get_main_queue()).
 *
 * @see pragmaAutoVacuum
**/
- (void)asyncVacuumWithCompletionBlock:(dispatch_block_t)completionBlock
{
	[self asyncVacuumWithCompletionQueue:NULL completionBlock:completionBlock];
}

/**
 * Performs a VACUUM on the sqlite database.
 *
 * This method operates as an asynchronous readWrite "transaction".
 * That is, it behaves in a similar fashion, and you may treat it as if it is a ReadWrite transaction.
 *
 * For more infomation on the VACUUM operation, see the sqlite docs:
 * http://sqlite.org/lang_vacuum.html
 *
 * Remember that YapDatabase operates in WAL mode, with "auto_vacuum=FULL" set.
 *
 * An optional completion block may be used.
 * Additionally the dispatch_queue to invoke the completion block may also be specified.
 * If NULL, dispatch_get_main_queue() is automatically used.
 * 
 * @see pragmaAutoVacuum
**/
- (void)asyncVacuumWithCompletionQueue:(dispatch_queue_t)completionQueue
                       completionBlock:(dispatch_block_t)completionBlock
{
	if (completionQueue == NULL && completionBlock != NULL)
		completionQueue = dispatch_get_main_queue();
	
	dispatch_async(connectionQueue, ^{ @autoreleasepool {
		
		if (longLivedReadTransaction)
		{
			if (throwExceptionsForImplicitlyEndingLongLivedReadTransaction)
			{
				@throw [self implicitlyEndingLongLivedReadTransactionException];
			}
			else
			{
				YDBLogWarn(@"Implicitly ending long-lived read transaction on connection %@, database %@",
						   self, database);
				
				[self endLongLivedReadTransaction];
			}
		}
		
		__preWriteQueue(self);
		dispatch_sync(database->writeQueue, ^{ @autoreleasepool {
			
			[self preVacuum];
			
			int status;
			
			status = sqlite3_exec(db, "PRAGMA auto_vacuum = FULL;", NULL, NULL, NULL);
			if (status != SQLITE_OK)
			{
				YDBLogError(@"Error setting PRAGMA auto_vacuum: %d %s", status, sqlite3_errmsg(db));
			}
			
			YDBLogVerbose(@"Starting VACUUM ...");
			
			status = sqlite3_exec(db, "VACUUM;", NULL, NULL, NULL);
			if (status != SQLITE_OK)
			{
				YDBLogError(@"Error performing VACUUM: %d %s", status, sqlite3_errmsg(db));
			}
			
			YDBLogVerbose(@"VACUUM complete !");
			
			[self postVacuum];
			
			if (completionBlock) {
				dispatch_async(completionQueue, completionBlock);
			}
			
		}}); // End dispatch_sync(database->writeQueue)
		__postWriteQueue(self);
	}});     // End dispatch_async(connectionQueue)
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Memory Tables
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSDictionary *)registeredMemoryTables
{
	// This method is INTERNAL
	
	return registeredMemoryTables;
}

- (BOOL)registerMemoryTable:(YapMemoryTable *)table withName:(NSString *)name
{
	// This method is INTERNAL
	
	if ([registeredMemoryTables objectForKey:name])
		return NO;
	
	NSMutableDictionary *newRegisteredMemoryTables = [registeredMemoryTables mutableCopy];
	[newRegisteredMemoryTables setObject:table forKey:name];
	
	registeredMemoryTables = [newRegisteredMemoryTables copy];
	registeredMemoryTablesChanged = YES;
	
	return YES;
}

- (void)unregisterMemoryTableWithName:(NSString *)name
{
	// This method is INTERNAL
	
	if ([registeredMemoryTables objectForKey:name])
	{
		NSMutableDictionary *newRegisteredMemoryTables = [registeredMemoryTables mutableCopy];
		[newRegisteredMemoryTables removeObjectForKey:name];
		
		registeredMemoryTables = [newRegisteredMemoryTables copy];
		registeredMemoryTablesChanged = YES;
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Long-lived read transactions are a great way to achive stability, especially in places like the main-thread.
 * However, they pose a unique problem. These long-lived transactions often start out by
 * locking the WAL (write ahead log). This prevents the WAL from ever getting reset,
 * and thus causes the WAL to potentially grow infinitely large. In order to allow the WAL to get properly reset,
 * we need the long-lived read transactions to "reset". That is, without changing their stable state (their snapshot),
 * we need them to restart the transaction, but this time without locking this WAL.
 * 
 * We use the maybeResetLongLivedReadTransaction method to achieve this.
**/
- (void)maybeResetLongLivedReadTransaction
{
	// Async dispatch onto the writeQueue so we know there aren't any other active readWrite transactions
	
	dispatch_async(database->writeQueue, ^{
		
		// Pause the writeQueue so readWrite operations can't interfere with us.
		// We abort if our connection has a readWrite transaction pending.
		
		BOOL abort = NO;
		
		OSSpinLockLock(&lock);
		{
			if (activeReadWriteTransaction) {
				abort = YES;
			}
			else if (!writeQueueSuspended) {
				dispatch_suspend(database->writeQueue);
				writeQueueSuspended = YES;
			}
		}
		OSSpinLockUnlock(&lock);
		
		if (abort) return;
		
		// Async dispatch onto our connectionQueue.
		
		dispatch_async(connectionQueue, ^{
			
			// If possible, silently reset the longLivedReadTransaction (same snapshot, no longer locking the WAL)
			
			if (longLivedReadTransaction && (snapshot == [database snapshot]))
			{
				NSArray *empty = [self beginLongLivedReadTransaction];
				
				if ([empty count] != 0)
				{
					YDBLogError(@"Core logic failure! "
					            @"Silent longLivedReadTransaction reset resulted in non-empty notification array!");
				}
			}
			
			// Resume the writeQueue
			
			OSSpinLockLock(&lock);
			{
				if (writeQueueSuspended) {
					dispatch_resume(database->writeQueue);
					writeQueueSuspended = NO;
				}
			}
			OSSpinLockUnlock(&lock);
		});
	});
}

NS_INLINE void __preWriteQueue(YapDatabaseConnection *connection)
{
	OSSpinLockLock(&connection->lock);
	{
		if (connection->writeQueueSuspended) {
			dispatch_resume(connection->database->writeQueue);
			connection->writeQueueSuspended = NO;
		}
		connection->activeReadWriteTransaction = YES;
	}
	OSSpinLockUnlock(&connection->lock);
}

NS_INLINE void __postWriteQueue(YapDatabaseConnection *connection)
{
	OSSpinLockLock(&connection->lock);
	{
		connection->activeReadWriteTransaction = NO;
	}
	OSSpinLockUnlock(&connection->lock);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Exceptions
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSException *)nonMainThreadException
{
	NSString *connectionName = self.name;
	NSString *nameInfo = ([connectionName length] > 0) ? [NSString stringWithFormat:@" <%@>", connectionName] : @"";
	
	NSString *reason = [NSString stringWithFormat:
	    @"YapDatabaseConnection[%p]%@ - unpermitted attempt to execute transaction on nom-main thread",
	    self, nameInfo];
	
	NSDictionary *userInfo = @{ NSLocalizedRecoverySuggestionErrorKey:
		@"This connection was configured (via the permittedTransactions property) to only allow transactions"
		@" to be executed from the main-thread. Presumably this connection is dedicated to UI tasks, and thus"
		@" its use on background threads is being discouraged in order to guarantee the connection never blocks."
		@" Perhaps you're using the wrong dedicated connection."
		@" Or you need to create a temporary connection via [database newConnection]."};
	
	return [NSException exceptionWithName:@"YapDatabaseException" reason:reason userInfo:userInfo];
}

#if YapDatabaseEnforcePermittedTransactions
- (NSException *)unpermittedTransactionException:(NSUInteger)transactionFlag
{
	NSUInteger flags = self.permittedTransactions;
	
	NSString *connectionName = self.name;
	NSString *nameInfo = ([connectionName length] > 0) ? [NSString stringWithFormat:@" <%@>", connectionName] : @"";
	
	NSString *unpermittedTransaction = @"unknownTransaction";
	if (transactionFlag == YDB_SyncReadTransaction)
		unpermittedTransaction = @"(sync)readTransaction";
	if (transactionFlag == YDB_AsyncReadTransaction)
		unpermittedTransaction = @"asyncReadTransaction";
	if (transactionFlag == YDB_SyncReadWriteTransaction)
		unpermittedTransaction = @"(sync)readWriteTransaction";
	if (transactionFlag == YDB_AsyncReadWriteTransaction)
		unpermittedTransaction = @"asyncReadWriteTransaction";
	
	NSString *reason = [NSString stringWithFormat:
	    @"YapDatabaseConnection[%p]%@ - unpermitted attempt to execute %@", self, nameInfo, unpermittedTransaction];
	
	NSMutableArray *permittedComponents = [NSMutableArray arrayWithCapacity:4];
	if (flags & YDB_SyncReadTransaction)
		[permittedComponents addObject:@"(sync)readTransaction"];
	if (flags & YDB_AsyncReadTransaction)
		[permittedComponents addObject:@"asyncReadTransaction"];
	if (flags & YDB_SyncReadWriteTransaction)
		[permittedComponents addObject:@"(sync)readWriteTransaction"];
	if (flags & YDB_AsyncReadWriteTransaction)
		[permittedComponents addObject:@"asyncReadWriteTransaction"];
	
	NSString *suggestion = [NSString stringWithFormat:
	    @"This connection was configured (via the permittedTransactions property) to only allow"
	    @" certain types of transactions. The permittedTransactions are: %@",
	    [permittedComponents componentsJoinedByString:@", "]];
	
	NSDictionary *userInfo = @{ NSLocalizedRecoverySuggestionErrorKey: suggestion };
	
	return [NSException exceptionWithName:@"YapDatabaseException" reason:reason userInfo:userInfo];
}
#endif

- (NSException *)implicitlyEndingLongLivedReadTransactionException
{
	NSString *reason = [NSString stringWithFormat:
		@"Database <%@: %p> had long-lived read transaction implicitly ended by executing a read-write transaction.",
		NSStringFromClass([self class]), self];
	
	NSDictionary *userInfo = @{ NSLocalizedRecoverySuggestionErrorKey:
		@"Connections with long-lived read transactions are generally designed to be read-only connections."
		@" As such, you'll want to use a separate connection for the read-write transaction."
		@" If this is not the case (very, very, very rare) you can disable this exception using"
		@" disableExceptionsForImplicitlyEndingLongLivedReadTransaction."
		@" Keep in mind that if you disable these exceptions without understanding why they're enabled by default"
		@" then you're inevitably creating a hard-to-reproduce bug and likely a few crashes too."
		@" Don't be lazy. You've been warned."};
	
	return [NSException exceptionWithName:@"YapDatabaseException" reason:reason userInfo:userInfo];
}

@end

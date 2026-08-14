package playground

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/stretchr/testify/require"
)

func TestERC4337PredeploysAreAValidAlloc(t *testing.T) {
	var alloc types.GenesisAlloc
	require.NoError(t, json.Unmarshal(ERC4337Predeploys(), &alloc))

	// every address a bundler needs to be present from block 0
	for _, addr := range []string{
		EntryPointV06Address,
		SimpleAccountFactoryV06Address,
		DeterministicDeployerAddress,
		// the EntryPoint holds SenderCreator's address as an immutable, so account
		// creation reverts with AA13 if it is missing
		"0x7fc98430eAEdbb6070B35B39D798725049088348",
		// the implementation the factory clones behind an ERC-1967 proxy
		"0x8ABB13360b87Be5EEb1B98647A016adD927a136c",
	} {
		account, ok := alloc[common.HexToAddress(addr)]
		require.True(t, ok, "missing predeploy %s", addr)
		require.NotEmpty(t, account.Code, "predeploy %s has no code", addr)
	}

	// the EntryPoint's reentrancy guard must be initialised, otherwise the first
	// handleOps call reverts
	entryPoint := alloc[common.HexToAddress(EntryPointV06Address)]
	require.NotEmpty(t, entryPoint.Storage, "EntryPoint is missing its storage")
}

func TestParseBundlerKind(t *testing.T) {
	for _, name := range []string{"alto", "rundler"} {
		kind, err := ParseBundlerKind(name)
		require.NoError(t, err)
		require.Equal(t, name, string(kind))
	}

	_, err := ParseBundlerKind("nope")
	require.Error(t, err)
	require.Contains(t, err.Error(), "alto, rundler")
}

// The bundler signs its own transactions, so its accounts must be funded at genesis and
// must not collide with each other.
func TestBundlerKeysArePrefundedAndDistinct(t *testing.T) {
	prefunded := make(map[string]bool, len(staticPrefundedAccounts))
	for _, key := range staticPrefundedAccounts {
		prefunded[key] = true
	}

	seen := map[string]bool{}
	for _, key := range append(bundlerExecutorKeys(), bundlerUtilityKey()) {
		require.True(t, prefunded[key], "bundler key %s is not prefunded", key)
		require.False(t, seen[key], "bundler key %s is used twice", key)
		seen[key] = true
	}

	// index 0 is what `builder-playground test` and contender use
	require.NotContains(t, seen, staticPrefundedAccounts[0])
}

func testBundlerCtx() *ExContext {
	return &ExContext{LogLevel: LevelInfo, Contender: &ContenderContext{}}
}

// argValue returns the value following the given flag.
func argValue(t *testing.T, args []string, flag string) string {
	t.Helper()
	for i, arg := range args {
		if arg == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	t.Fatalf("flag %s not found in %v", flag, args)
	return ""
}

func dependsOnHealthy(svc *Service, name string) bool {
	for _, dep := range svc.DependsOn {
		if dep.Name == name && dep.Condition == DependsOnConditionHealthy {
			return true
		}
	}
	return false
}

func TestL1RecipeBundlerWiring(t *testing.T) {
	findService := func(t *testing.T, c *Component, name string) *Service {
		t.Helper()
		svc := c.FindService(name)
		require.NotNil(t, svc, "service %s not found", name)
		return svc
	}

	t.Run("no bundler leaves the recipe untouched", func(t *testing.T) {
		recipe := &L1Recipe{}
		require.Nil(t, recipe.Artifacts().l1PredeployData)

		component := recipe.Apply(testBundlerCtx())
		require.Nil(t, component.FindService("bundler"))
		require.Equal(t, "admin,eth,web3,net,rpc,mev,flashbots",
			argValue(t, findService(t, component, "el").Args, "--http.api"))
	})

	for _, tc := range []struct {
		bundler BundlerKind
		image   string
	}{
		{BundlerAlto, "ghcr.io/pimlicolabs/alto"},
		{BundlerRundler, "alchemyplatform/rundler"},
	} {
		t.Run(string(tc.bundler), func(t *testing.T) {
			recipe := &L1Recipe{bundler: tc.bundler}
			require.NotEmpty(t, recipe.Artifacts().l1PredeployData)

			component := recipe.Apply(testBundlerCtx())

			bundler := findService(t, component, "bundler")
			require.Equal(t, tc.image, bundler.Image)

			// safe mode needs debug_traceCall over HTTP
			require.Contains(t, argValue(t, findService(t, component, "el").Args, "--http.api"), "debug,trace")

			// the bundler must wait for the execution client
			require.True(t, dependsOnHealthy(bundler, "el"), "bundler does not wait for el")
		})
	}

	t.Run("alto defaults to safe mode and honours --bundler-unsafe", func(t *testing.T) {
		safe := (&L1Recipe{bundler: BundlerAlto}).Apply(testBundlerCtx())
		require.Contains(t, strings.Join(findService(t, safe, "bundler").Args, " "), "--safeMode true")

		unsafe := (&L1Recipe{bundler: BundlerAlto, bundlerUnsafe: true}).Apply(testBundlerCtx())
		require.Contains(t, strings.Join(findService(t, unsafe, "bundler").Args, " "), "--safeMode false")
	})

	t.Run("rundler defaults to safe mode and honours --bundler-unsafe", func(t *testing.T) {
		safe := (&L1Recipe{bundler: BundlerRundler}).Apply(testBundlerCtx())
		require.NotContains(t, findService(t, safe, "bundler").Env, "UNSAFE")

		unsafe := (&L1Recipe{bundler: BundlerRundler, bundlerUnsafe: true}).Apply(testBundlerCtx())
		require.Equal(t, "true", findService(t, unsafe, "bundler").Env["UNSAFE"])
	})
}

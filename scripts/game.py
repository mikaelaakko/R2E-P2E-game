from brownie import THRONE, GameOfRisk, Battle, Traits3, accounts
from scripts.helper_functions import get_account


def deploy():
    account = get_account()

    throne_con = THRONE[-1]
    traits_con = Traits3[-1]

    game_con = GameOfRisk.deploy(
        throne_con,
        traits_con,
        50000,
        {"from": account},
        publish_source=True,
    )


def set_battle():
    account = get_account()

    game_con = GameOfRisk[-1]
    battle_con = Battle[-1]

    add_tx = game_con.setBattle(battle_con.address, {"from": account})
    add_tx.wait(1)


def set_random_source():
    account = get_account()

    game_con = GameOfRisk[-1]
    # seed_con = Seed[-1]

    add_tx = game_con.setRandomSource("", {"from": account})
    add_tx.wait(1)


def set_merkle_root():
    account = get_account()

    game_con = GameOfRisk[-1]
    # seed_con = Seed[-1]

    add_tx = game_con.setMerkleRoot("", {"from": account})
    add_tx.wait(1)


def test_mint():
    account = get_account()

    game_con = GameOfRisk[-1]
    # seed_con = Seed[-1]
    fee = 1450000000000000000
    mint_tx = game_con.mint(1, True, {"from": account, "value": fee})
    mint_tx.wait(1)


def main():
    # deploy()
    # set_battle()
    # set_random_source()
    # set_merkle_root()
    test_mint()
